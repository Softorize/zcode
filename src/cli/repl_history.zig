const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const xdg = @import("../core/xdg.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

pub const SearchItem = struct {
    prompt: []u8,
    timestamp: i64 = 0,
};

const PromptLogEntry = struct {
    ts: i64,
    workspace: []const u8,
    prompt: []const u8,
};

pub fn freeSearchItems(allocator: std.mem.Allocator, items: []SearchItem) void {
    for (items) |item| allocator.free(item.prompt);
    allocator.free(items);
}

pub fn appendPrompt(allocator: std.mem.Allocator, workspace: []const u8, prompt: []const u8) void {
    appendPromptInner(allocator, workspace, prompt) catch {};
}

fn appendPromptInner(allocator: std.mem.Allocator, workspace: []const u8, prompt: []const u8) !void {
    const state_dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(state_dir);
    try appendPromptInStateDir(allocator, state_dir, workspace, prompt);
}

fn historyLogPathInStateDir(allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_dir, "prompt-history.jsonl" });
}

fn appendPromptInStateDir(allocator: std.mem.Allocator, state_dir: []const u8, workspace: []const u8, prompt: []const u8) !void {
    if (prompt.len == 0) return;

    std.Io.Dir.cwd().createDirPath(rt.io, state_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const log_path = try historyLogPathInStateDir(allocator, state_dir);
    defer allocator.free(log_path);

    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std_io.openFlagsAlloc(rt.gpa, log_path, flags, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(rt.io);

    var raw = std_io.StringBuilder.init(allocator);
    defer raw.deinit();
    try raw.writer().print("{f}", .{std.json.fmt(
        PromptLogEntry{
            .ts = clock.nowSeconds(),
            .workspace = workspace,
            .prompt = prompt,
        },
        .{},
    )});

    var safe = std_io.StringBuilder.init(allocator);
    defer safe.deinit();
    try parse_helpers.appendNdjsonSafe(&safe, raw.items());
    try safe.append('\n');
    try file.writeStreamingAll(rt.io, safe.items());
}

/// Remove the most recent persisted prompt belonging to `workspace` from the
/// global prompt-history log and return the removed prompt text (caller owns
/// the slice) so the caller can restore it to the input. Returns null when no
/// entry for the workspace exists. Entries for other workspaces are left
/// untouched. Used by the restore-on-interrupt path: a cancelled turn pops the
/// prompt it just logged so it does not linger in history while the user
/// edits/resubmits it. Errors are swallowed by callers that do not care.
pub fn removeLastForWorkspace(allocator: std.mem.Allocator, workspace: []const u8) ?[]u8 {
    return removeLastForWorkspaceInner(allocator, workspace) catch null;
}

fn removeLastForWorkspaceInner(allocator: std.mem.Allocator, workspace: []const u8) !?[]u8 {
    const state_dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(state_dir);
    return removeLastForWorkspaceInStateDir(allocator, state_dir, workspace);
}

/// Test-seam variant of removeLastForWorkspace that takes an explicit state
/// dir, mirroring appendPromptInStateDir. Reads the JSONL, drops the last line
/// whose workspace matches, and rewrites the file atomically (temp + rename)
/// so an interrupt mid-rewrite can't leave a torn log.
fn removeLastForWorkspaceInStateDir(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    workspace: []const u8,
) !?[]u8 {
    const log_path = try historyLogPathInStateDir(allocator, state_dir);
    defer allocator.free(log_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    // Walk lines from the end to find the last entry whose workspace matches.
    // Record the byte span [line_start, line_end) of that line (without its
    // trailing newline) so we can rewrite the file omitting exactly it.
    var removed_prompt: ?[]u8 = null;
    var remove_start: usize = 0;
    var remove_end: usize = 0;
    var found = false;

    var end = bytes.len;
    while (end > 0) {
        while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        const nl = std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n');
        const line_start = if (nl) |idx| idx + 1 else 0;
        const line = bytes[line_start..end];
        const next_end = if (nl) |idx| idx else 0;

        if (line.len != 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
                end = next_end;
                continue;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                const obj = parsed.value.object;
                const workspace_value = obj.get("workspace");
                const prompt_value = obj.get("prompt");
                if (workspace_value != null and workspace_value.? == .string and
                    std.mem.eql(u8, workspace_value.?.string, workspace))
                {
                    const prompt_text = if (prompt_value != null and prompt_value.? == .string)
                        prompt_value.?.string
                    else
                        "";
                    removed_prompt = try allocator.dupe(u8, prompt_text);
                    remove_start = line_start;
                    remove_end = end;
                    found = true;
                    break;
                }
            }
        }

        end = next_end;
    }

    if (!found) return null;
    errdefer if (removed_prompt) |p| allocator.free(p);

    // Rebuild the file omitting bytes[remove_start..remove_end] and exactly one
    // trailing newline after it (so we don't leave a blank line behind).
    var rebuilt = std_io.StringBuilder.init(allocator);
    defer rebuilt.deinit();

    try rebuilt.appendSlice(bytes[0..remove_start]);
    var tail_start = remove_end;
    // Skip one immediate newline (and a paired \r) that terminated the removed line.
    if (tail_start < bytes.len and bytes[tail_start] == '\r') tail_start += 1;
    if (tail_start < bytes.len and bytes[tail_start] == '\n') tail_start += 1;
    try rebuilt.appendSlice(bytes[tail_start..]);

    try writeHistoryLogAtomic(allocator, log_path, rebuilt.items());
    return removed_prompt;
}

/// Atomically replace the prompt-history log via a sibling .tmp + rename so an
/// interrupt between truncate and write can't leave a torn file for the next
/// reader. Mirrors store.zig writeSidecarAtomic (0o600, sync, errdefer cleanup).
fn writeHistoryLogAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

pub fn buildSearchItems(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    session_prompts: []const []const u8,
    max_items: usize,
) ![]SearchItem {
    const state_dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(state_dir);
    return buildSearchItemsFromStateDir(allocator, state_dir, workspace, session_prompts, max_items);
}

fn buildSearchItemsFromStateDir(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    workspace: []const u8,
    session_prompts: []const []const u8,
    max_items: usize,
) ![]SearchItem {
    var items = std.array_list.Managed(SearchItem).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.prompt);
        items.deinit();
    }

    if (max_items == 0) return items.toOwnedSlice();

    var idx = session_prompts.len;
    while (idx > 0 and items.items.len < max_items) {
        idx -= 1;
        const prompt = std.mem.trim(u8, session_prompts[idx], " \t\r\n");
        if (prompt.len == 0) continue;
        try appendUniqueItem(&items, allocator, prompt, 0);
    }

    const persisted = try loadWorkspaceHistoryFromStateDir(allocator, state_dir, workspace, max_items);
    defer freeSearchItems(allocator, persisted);

    for (persisted) |item| {
        if (items.items.len >= max_items) break;
        try appendUniqueItem(&items, allocator, item.prompt, item.timestamp);
    }

    return items.toOwnedSlice();
}

fn loadWorkspaceHistoryFromStateDir(
    allocator: std.mem.Allocator,
    state_dir: []const u8,
    workspace: []const u8,
    max_items: usize,
) ![]SearchItem {
    var items = std.array_list.Managed(SearchItem).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.prompt);
        items.deinit();
    }

    if (max_items == 0) return items.toOwnedSlice();

    const log_path = try historyLogPathInStateDir(allocator, state_dir);
    defer allocator.free(log_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return items.toOwnedSlice(),
        else => return err,
    };
    defer allocator.free(bytes);

    var end = bytes.len;
    while (end > 0 and items.items.len < max_items) {
        while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        const start = std.mem.lastIndexOfScalar(u8, bytes[0..end], '\n') orelse 0;
        const line = if (start == 0) bytes[0..end] else bytes[start + 1 .. end];
        end = start;

        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => parsed.value.object,
            else => continue,
        };

        const prompt_value = obj.get("prompt") orelse continue;
        const workspace_value = obj.get("workspace") orelse continue;
        if (prompt_value != .string or workspace_value != .string) continue;
        if (!std.mem.eql(u8, workspace_value.string, workspace)) continue;

        const prompt = std.mem.trim(u8, prompt_value.string, " \t\r\n");
        if (prompt.len == 0) continue;

        const ts = if (obj.get("ts")) |value| switch (value) {
            .integer => value.integer,
            else => 0,
        } else 0;

        try appendUniqueItem(&items, allocator, prompt, ts);
    }

    return items.toOwnedSlice();
}

fn appendUniqueItem(items: *std.array_list.Managed(SearchItem), allocator: std.mem.Allocator, prompt: []const u8, timestamp: i64) !void {
    for (items.items) |item| {
        if (std.mem.eql(u8, item.prompt, prompt)) return;
    }
    try items.append(.{
        .prompt = try allocator.dupe(u8, prompt),
        .timestamp = timestamp,
    });
}

const testing = std.testing;

test "loadWorkspaceHistoryFromStateDir returns newest-first unique prompts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(state_dir);

    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "first");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "second");
    try appendPromptInStateDir(testing.allocator, state_dir, "/other", "ignore me");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "second");

    const items = try loadWorkspaceHistoryFromStateDir(testing.allocator, state_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, items);

    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("second", items[0].prompt);
    try testing.expectEqualStrings("first", items[1].prompt);
}

test "removeLastForWorkspaceInStateDir pops newest workspace prompt and preserves others" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(state_dir);

    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "one");
    try appendPromptInStateDir(testing.allocator, state_dir, "/other", "other-keep");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "two");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "three");

    // Removes the newest /repo entry ("three") and returns its text.
    const removed = try removeLastForWorkspaceInStateDir(testing.allocator, state_dir, "/repo");
    try testing.expect(removed != null);
    defer testing.allocator.free(removed.?);
    try testing.expectEqualStrings("three", removed.?);

    // The file now has two /repo prompts left, newest-first "two" then "one",
    // and the /other entry is untouched.
    const repo_items = try loadWorkspaceHistoryFromStateDir(testing.allocator, state_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 2), repo_items.len);
    try testing.expectEqualStrings("two", repo_items[0].prompt);
    try testing.expectEqualStrings("one", repo_items[1].prompt);

    const other_items = try loadWorkspaceHistoryFromStateDir(testing.allocator, state_dir, "/other", 10);
    defer freeSearchItems(testing.allocator, other_items);
    try testing.expectEqual(@as(usize, 1), other_items.len);
    try testing.expectEqualStrings("other-keep", other_items[0].prompt);
}

test "removeLastForWorkspaceInStateDir returns null for unknown workspace and missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(state_dir);

    // Missing log file -> null, no crash.
    const missing = try removeLastForWorkspaceInStateDir(testing.allocator, state_dir, "/repo");
    try testing.expect(missing == null);

    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "only");

    // Workspace with no entries -> null, /repo entry preserved.
    const none = try removeLastForWorkspaceInStateDir(testing.allocator, state_dir, "/elsewhere");
    try testing.expect(none == null);

    const repo_items = try loadWorkspaceHistoryFromStateDir(testing.allocator, state_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 1), repo_items.len);
    try testing.expectEqualStrings("only", repo_items[0].prompt);
}

test "removeLastForWorkspaceInStateDir leaves remaining lines parseable (no torn file)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(state_dir);

    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "alpha");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "beta");

    const removed = try removeLastForWorkspaceInStateDir(testing.allocator, state_dir, "/repo");
    try testing.expect(removed != null);
    defer testing.allocator.free(removed.?);
    try testing.expectEqualStrings("beta", removed.?);

    // A second pop should now return "alpha", proving the rewrite produced a
    // valid single-line JSONL (not a blank line or a fused record).
    const removed2 = try removeLastForWorkspaceInStateDir(testing.allocator, state_dir, "/repo");
    try testing.expect(removed2 != null);
    defer testing.allocator.free(removed2.?);
    try testing.expectEqualStrings("alpha", removed2.?);

    const repo_items = try loadWorkspaceHistoryFromStateDir(testing.allocator, state_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 0), repo_items.len);
}

test "buildSearchItemsFromStateDir merges session prompts before persisted history" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const state_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(state_dir);

    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "persisted older");
    try appendPromptInStateDir(testing.allocator, state_dir, "/repo", "persisted duplicate");

    const session_prompts = [_][]const u8{
        "persisted duplicate",
        "session latest",
    };

    const items = try buildSearchItemsFromStateDir(testing.allocator, state_dir, "/repo", session_prompts[0..], 10);
    defer freeSearchItems(testing.allocator, items);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("session latest", items[0].prompt);
    try testing.expectEqualStrings("persisted duplicate", items[1].prompt);
    try testing.expectEqualStrings("persisted older", items[2].prompt);
}
