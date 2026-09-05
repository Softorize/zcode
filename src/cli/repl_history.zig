const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const xdg = @import("../core/xdg.zig");
const paths = @import("../core/paths.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

pub const SearchItem = struct {
    prompt: []u8,
    timestamp: i64 = 0,
};

/// sessions-storage-06: on-disk record shape, matching the reference's
/// `~/.claude/history.jsonl` `LogEntry` type verbatim (`{display,
/// pastedContents, timestamp, project, sessionId?}` -- edualc/src/
/// history.ts:219-225) so a tool reading zcode's history file (or the
/// reference reading zcode's, on a shared machine) sees the same shape.
/// `pastedContents` is always `{}` for now (zcode does not yet track pasted
/// attachments in a schema-matched way); `sessionId` is always "" (zcode's
/// history log has no live session-id plumbing yet) -- both are honest
/// placeholders for fields the reference schema declares optional/present.
const PromptLogEntry = struct {
    display: []const u8,
    pastedContents: PastedContents = .{},
    timestamp: i64,
    project: []const u8,
    sessionId: []const u8 = "",
};

/// Deliberately empty: serializes to `{}`, matching the reference's
/// `pastedContents: {}` shape for an entry with no pasted attachments.
const PastedContents = struct {};

pub fn freeSearchItems(allocator: std.mem.Allocator, items: []SearchItem) void {
    for (items) |item| allocator.free(item.prompt);
    allocator.free(items);
}

pub fn appendPrompt(allocator: std.mem.Allocator, workspace: []const u8, prompt: []const u8) void {
    appendPromptInner(allocator, workspace, prompt) catch {};
}

fn appendPromptInner(allocator: std.mem.Allocator, workspace: []const u8, prompt: []const u8) !void {
    const home_dir = try resolveHistoryHomeDir(allocator);
    defer allocator.free(home_dir);
    try appendPromptInHomeDir(allocator, home_dir, workspace, prompt);
}

/// sessions-storage-06: resolve the directory the history log lives directly
/// under -- `{zcode_home}/history.jsonl` (matching the reference's
/// `~/.claude/history.jsonl`, placed directly under the config home, not a
/// separate XDG state dir) -- and opportunistically run the one-time legacy
/// migration (see `migrateLegacyHistoryIfNeeded`) before returning it, so
/// every production entry point (append/remove/search) transparently picks
/// up history recorded under the old `<xdg_state>/zcode/prompt-history.jsonl`
/// location and schema.
fn resolveHistoryHomeDir(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    const home_dir = try allocator.dupe(u8, resolved.zcode_home);
    migrateLegacyHistoryIfNeeded(allocator, home_dir);
    return home_dir;
}

fn historyLogPathInHomeDir(allocator: std.mem.Allocator, home_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ home_dir, "history.jsonl" });
}

/// The pre sessions-storage-06 location: `<xdg_state>/zcode/prompt-history.jsonl`,
/// read only by the one-time migration below (never written to again, and
/// never deleted -- old user data is left in place untouched).
fn legacyHistoryLogPathInStateDir(allocator: std.mem.Allocator, state_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ state_dir, "prompt-history.jsonl" });
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

/// sessions-storage-06: one-time migration from the legacy
/// `<xdg_state>/zcode/prompt-history.jsonl` file (schema `{ts, workspace,
/// prompt}`) to the reference-shaped `{zcode_home}/history.jsonl` (schema
/// `{display, pastedContents, timestamp, project, sessionId}`). A no-op once
/// the new file exists (even if migration produced zero translatable lines,
/// re-checking the legacy file on every call is cheap -- this only runs once
/// per submitted prompt / history read, not a hot path). The legacy file is
/// left in place untouched; only translated COPIES land in the new file.
/// Best-effort: any error degrades to "nothing migrated this time", the same
/// as `appendPrompt` degrading its own errors, so a permissions hiccup here
/// never blocks the REPL from logging or reading history going forward.
fn migrateLegacyHistoryIfNeeded(allocator: std.mem.Allocator, home_dir: []const u8) void {
    migrateLegacyHistoryIfNeededInner(allocator, home_dir) catch {};
}

fn migrateLegacyHistoryIfNeededInner(allocator: std.mem.Allocator, home_dir: []const u8) !void {
    const new_path = try historyLogPathInHomeDir(allocator, home_dir);
    defer allocator.free(new_path);
    if (pathExists(new_path)) return;

    const legacy_dir = try xdg.getZcodeStateDir(allocator);
    defer allocator.free(legacy_dir);
    const legacy_path = try legacyHistoryLogPathInStateDir(allocator, legacy_dir);
    defer allocator.free(legacy_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, legacy_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);

    var translated = std_io.StringBuilder.init(allocator);
    defer translated.deinit();

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;

        const prompt_v = obj.get("prompt") orelse continue;
        const workspace_v = obj.get("workspace") orelse continue;
        if (prompt_v != .string or workspace_v != .string) continue;
        const ts: i64 = if (obj.get("ts")) |v| switch (v) {
            .integer => |n| n,
            else => 0,
        } else 0;

        var raw = std_io.StringBuilder.init(allocator);
        defer raw.deinit();
        try raw.writer().print("{f}", .{std.json.fmt(
            PromptLogEntry{
                .display = prompt_v.string,
                .timestamp = ts,
                .project = workspace_v.string,
            },
            .{},
        )});
        try parse_helpers.appendNdjsonSafe(&translated, raw.items());
        try translated.append('\n');
    }

    // Nothing translatable (e.g. an empty or fully-unparseable legacy file):
    // leave the new file absent so a later run with a fixed/non-empty
    // legacy file can still migrate.
    if (translated.items().len == 0) return;

    std.Io.Dir.cwd().createDirPath(rt.io, home_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std_io.openFlagsAlloc(rt.gpa, new_path, flags, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, translated.items());
}

fn appendPromptInHomeDir(allocator: std.mem.Allocator, home_dir: []const u8, workspace: []const u8, prompt: []const u8) !void {
    if (prompt.len == 0) return;

    std.Io.Dir.cwd().createDirPath(rt.io, home_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const log_path = try historyLogPathInHomeDir(allocator, home_dir);
    defer allocator.free(log_path);

    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const fd = try std_io.openFlagsAlloc(rt.gpa, log_path, flags, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(rt.io);

    var raw = std_io.StringBuilder.init(allocator);
    defer raw.deinit();
    try raw.writer().print("{f}", .{std.json.fmt(
        PromptLogEntry{
            .display = prompt,
            .timestamp = clock.nowSeconds(),
            .project = workspace,
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
    const home_dir = try resolveHistoryHomeDir(allocator);
    defer allocator.free(home_dir);
    return removeLastForWorkspaceInHomeDir(allocator, home_dir, workspace);
}

/// Test-seam variant of removeLastForWorkspace that takes an explicit home
/// dir, mirroring appendPromptInHomeDir. Reads the JSONL, drops the last line
/// whose project matches, and rewrites the file atomically (temp + rename)
/// so an interrupt mid-rewrite can't leave a torn log.
fn removeLastForWorkspaceInHomeDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    workspace: []const u8,
) !?[]u8 {
    const log_path = try historyLogPathInHomeDir(allocator, home_dir);
    defer allocator.free(log_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    // Walk lines from the end to find the last entry whose project matches.
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
                const project_value = obj.get("project");
                const display_value = obj.get("display");
                if (project_value != null and project_value.? == .string and
                    std.mem.eql(u8, project_value.?.string, workspace))
                {
                    const prompt_text = if (display_value != null and display_value.? == .string)
                        display_value.?.string
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
    const home_dir = try resolveHistoryHomeDir(allocator);
    defer allocator.free(home_dir);
    return buildSearchItemsFromHomeDir(allocator, home_dir, workspace, session_prompts, max_items);
}

fn buildSearchItemsFromHomeDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
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

    const persisted = try loadWorkspaceHistoryFromHomeDir(allocator, home_dir, workspace, max_items);
    defer freeSearchItems(allocator, persisted);

    for (persisted) |item| {
        if (items.items.len >= max_items) break;
        try appendUniqueItem(&items, allocator, item.prompt, item.timestamp);
    }

    return items.toOwnedSlice();
}

fn loadWorkspaceHistoryFromHomeDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    workspace: []const u8,
    max_items: usize,
) ![]SearchItem {
    var items = std.array_list.Managed(SearchItem).init(allocator);
    errdefer {
        for (items.items) |item| allocator.free(item.prompt);
        items.deinit();
    }

    if (max_items == 0) return items.toOwnedSlice();

    const log_path = try historyLogPathInHomeDir(allocator, home_dir);
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

        const display_value = obj.get("display") orelse continue;
        const project_value = obj.get("project") orelse continue;
        if (display_value != .string or project_value != .string) continue;
        if (!std.mem.eql(u8, project_value.string, workspace)) continue;

        const prompt = std.mem.trim(u8, display_value.string, " \t\r\n");
        if (prompt.len == 0) continue;

        const ts = if (obj.get("timestamp")) |value| switch (value) {
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

test "loadWorkspaceHistoryFromHomeDir returns newest-first unique prompts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "first");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "second");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/other", "ignore me");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "second");

    const items = try loadWorkspaceHistoryFromHomeDir(testing.allocator, home_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, items);

    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("second", items[0].prompt);
    try testing.expectEqualStrings("first", items[1].prompt);
}

test "removeLastForWorkspaceInHomeDir pops newest workspace prompt and preserves others" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "one");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/other", "other-keep");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "two");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "three");

    // Removes the newest /repo entry ("three") and returns its text.
    const removed = try removeLastForWorkspaceInHomeDir(testing.allocator, home_dir, "/repo");
    try testing.expect(removed != null);
    defer testing.allocator.free(removed.?);
    try testing.expectEqualStrings("three", removed.?);

    // The file now has two /repo prompts left, newest-first "two" then "one",
    // and the /other entry is untouched.
    const repo_items = try loadWorkspaceHistoryFromHomeDir(testing.allocator, home_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 2), repo_items.len);
    try testing.expectEqualStrings("two", repo_items[0].prompt);
    try testing.expectEqualStrings("one", repo_items[1].prompt);

    const other_items = try loadWorkspaceHistoryFromHomeDir(testing.allocator, home_dir, "/other", 10);
    defer freeSearchItems(testing.allocator, other_items);
    try testing.expectEqual(@as(usize, 1), other_items.len);
    try testing.expectEqualStrings("other-keep", other_items[0].prompt);
}

test "removeLastForWorkspaceInHomeDir returns null for unknown workspace and missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    // Missing log file -> null, no crash.
    const missing = try removeLastForWorkspaceInHomeDir(testing.allocator, home_dir, "/repo");
    try testing.expect(missing == null);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "only");

    // Workspace with no entries -> null, /repo entry preserved.
    const none = try removeLastForWorkspaceInHomeDir(testing.allocator, home_dir, "/elsewhere");
    try testing.expect(none == null);

    const repo_items = try loadWorkspaceHistoryFromHomeDir(testing.allocator, home_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 1), repo_items.len);
    try testing.expectEqualStrings("only", repo_items[0].prompt);
}

test "removeLastForWorkspaceInHomeDir leaves remaining lines parseable (no torn file)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "alpha");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "beta");

    const removed = try removeLastForWorkspaceInHomeDir(testing.allocator, home_dir, "/repo");
    try testing.expect(removed != null);
    defer testing.allocator.free(removed.?);
    try testing.expectEqualStrings("beta", removed.?);

    // A second pop should now return "alpha", proving the rewrite produced a
    // valid single-line JSONL (not a blank line or a fused record).
    const removed2 = try removeLastForWorkspaceInHomeDir(testing.allocator, home_dir, "/repo");
    try testing.expect(removed2 != null);
    defer testing.allocator.free(removed2.?);
    try testing.expectEqualStrings("alpha", removed2.?);

    const repo_items = try loadWorkspaceHistoryFromHomeDir(testing.allocator, home_dir, "/repo", 10);
    defer freeSearchItems(testing.allocator, repo_items);
    try testing.expectEqual(@as(usize, 0), repo_items.len);
}

test "buildSearchItemsFromHomeDir merges session prompts before persisted history" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "persisted older");
    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "persisted duplicate");

    const session_prompts = [_][]const u8{
        "persisted duplicate",
        "session latest",
    };

    const items = try buildSearchItemsFromHomeDir(testing.allocator, home_dir, "/repo", session_prompts[0..], 10);
    defer freeSearchItems(testing.allocator, items);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("session latest", items[0].prompt);
    try testing.expectEqualStrings("persisted duplicate", items[1].prompt);
    try testing.expectEqualStrings("persisted older", items[2].prompt);
}

// sessions-storage-06: on-disk schema/path parity with the reference.
test "appendPromptInHomeDir writes the reference-shaped record (display/pastedContents/timestamp/project/sessionId)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(home_dir);

    try appendPromptInHomeDir(testing.allocator, home_dir, "/repo", "hello world");

    const log_path = try historyLogPathInHomeDir(testing.allocator, home_dir);
    defer testing.allocator.free(log_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, log_path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(bytes);

    const line = std.mem.trim(u8, bytes, " \t\r\n");
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqualStrings("hello world", obj.get("display").?.string);
    try testing.expect(obj.get("pastedContents").? == .object);
    try testing.expectEqual(@as(usize, 0), obj.get("pastedContents").?.object.count());
    try testing.expect(obj.get("timestamp").? == .integer);
    try testing.expectEqualStrings("/repo", obj.get("project").?.string);
    try testing.expectEqualStrings("", obj.get("sessionId").?.string);
}

// sessions-storage-06: a pre-existing legacy `<xdg_state>/zcode/prompt-history.jsonl`
// (schema `{ts, workspace, prompt}`) is migrated -- translated, not moved --
// into the new `{zcode_home}/history.jsonl` the first time a production entry
// point (buildSearchItems here) runs, and the legacy file is left untouched.
test "sessions-storage-06: legacy prompt-history.jsonl migrates into history.jsonl on first read" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    const env_mod = @import("../core/env.zig");
    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");

    // Seed the legacy file directly (old schema, old location).
    try tmp.dir.createDirPath(rt.io, ".local/state/zcode");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".local/state/zcode/prompt-history.jsonl",
        .data =
        \\{"ts":100,"workspace":"/repo","prompt":"legacy one"}
        \\{"ts":200,"workspace":"/repo","prompt":"legacy two"}
        \\{"ts":300,"workspace":"/other","prompt":"legacy other"}
        \\
        ,
    });

    const empty_session_prompts = [_][]const u8{};
    const items = try buildSearchItems(allocator, "/repo", empty_session_prompts[0..], 10);
    defer freeSearchItems(allocator, items);

    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("legacy two", items[0].prompt);
    try testing.expectEqualStrings("legacy one", items[1].prompt);

    // Migrated into the NEW location with the NEW schema.
    const new_path = try std.fs.path.join(allocator, &.{ root, ".zcode", "history.jsonl" });
    defer allocator.free(new_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, new_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"display\":\"legacy one\"") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"project\":\"/repo\"") != null);

    // The legacy file is left in place, untouched.
    const legacy_path = try std.fs.path.join(allocator, &.{ root, ".local", "state", "zcode", "prompt-history.jsonl" });
    defer allocator.free(legacy_path);
    const legacy_bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, legacy_path, allocator, .limited(64 * 1024));
    defer allocator.free(legacy_bytes);
    try testing.expect(std.mem.indexOf(u8, legacy_bytes, "\"workspace\":\"/repo\"") != null);
}
