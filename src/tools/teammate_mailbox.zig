//! Per-teammate mailbox storage (swarm-tasks-08). Each teammate has an inbox
//! file under `state/messages/<team>/<recipient>.inbox` holding one JSON record
//! per line (NDJSON). SendMessage routes a directed message to a single inbox,
//! or broadcasts to every team member's inbox.
//!
//! The reference (`utils/teammateMailbox.ts`) keeps a JSON-array file guarded by
//! a proper-lockfile and rewrites it on every append. We use the simpler
//! append-only NDJSON form the plan prescribes: `O_APPEND` (the same pattern as
//! `team.zig`'s team-wide log) serializes concurrent writers without a
//! read-modify-write race, and each record is a self-contained JSON object so a
//! torn write at most loses a trailing line rather than corrupting the file.
//!
//! Auto-delivery (draining an inbox into a running/idle teammate's turn) is
//! wired in a later task; this module lands the storage + addressing only.

const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const std_io = @import("../core/std_io.zig");
const helpers = @import("helpers.zig");

const MESSAGES_SUBPATH = helpers.MESSAGES_SUBPATH;

/// Cap on a single inbox file when reading it back, so a runaway producer
/// cannot make a reader allocate without bound. 4 MiB is far larger than any
/// realistic message backlog.
const MAX_INBOX_BYTES = 4 * 1024 * 1024;

/// One delivered message. Every string field is owned by the allocator passed
/// to `readMailbox`/`drainMailbox`; free a slice via `freeMessages`.
pub const MailboxMessage = struct {
    from: []u8,
    text: []u8,
    summary: []u8,
    timestamp: i64,
};

pub fn freeMessages(allocator: std.mem.Allocator, messages: []MailboxMessage) void {
    for (messages) |m| {
        allocator.free(m.from);
        allocator.free(m.text);
        allocator.free(m.summary);
    }
    allocator.free(messages);
}

/// Absolute path to a recipient's inbox file:
/// `<cwd>/state/messages/<team>/<recipient>.inbox`. The team subdirectory is
/// created if missing. Both `team` and `recipient` must be safe identifiers
/// (the caller is expected to gate them; we re-check here for defense in
/// depth). Caller frees.
pub fn inboxPathAlloc(allocator: std.mem.Allocator, cwd: []const u8, team: []const u8, recipient: []const u8) ![]u8 {
    if (!helpers.isSafeIdentifier(team)) return error.InvalidTeamName;
    if (!helpers.isSafeIdentifier(recipient)) return error.InvalidRecipientName;

    const team_rel = try std.fs.path.join(allocator, &.{ MESSAGES_SUBPATH, team });
    defer allocator.free(team_rel);
    const team_dir = try helpers.ensureWorkspaceDirPath(allocator, cwd, team_rel);
    defer allocator.free(team_dir);

    return std.fmt.allocPrint(allocator, "{s}/{s}.inbox", .{ team_dir, recipient });
}

/// Append a single message record to `recipient`'s inbox. The `summary` may be
/// empty (the field is still written, as the empty string). Mirrors
/// `writeToMailbox` (teammateMailbox.ts:134-192): from / text / summary /
/// timestamp. Uses `O_APPEND` so concurrent writers cannot interleave.
pub fn writeToMailbox(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team: []const u8,
    recipient: []const u8,
    from: []const u8,
    text: []const u8,
    summary: []const u8,
) !void {
    const path = try inboxPathAlloc(allocator, cwd, team, recipient);
    defer allocator.free(path);

    const line = try encodeRecord(allocator, from, text, summary, clock.nowSeconds());
    defer allocator.free(line);

    const file = try openAppendFile(path);
    defer file.close(rt.io);
    try std_io.fileWriter(file).writeAll(line);
}

/// Read every message currently in `recipient`'s inbox without modifying the
/// file. Returns an empty slice (not an error) when the inbox does not yet
/// exist. Caller frees via `freeMessages`.
pub fn readMailbox(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team: []const u8,
    recipient: []const u8,
) ![]MailboxMessage {
    const path = try inboxPathAlloc(allocator, cwd, team, recipient);
    defer allocator.free(path);

    const data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(MAX_INBOX_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(MailboxMessage, 0),
        else => return err,
    };
    defer allocator.free(data);

    return parseRecords(allocator, data);
}

/// Read every message and then truncate the inbox to empty, so the next read
/// returns nothing. Returns an empty slice when the inbox does not exist.
/// Mirrors the reference drain semantics used by auto-delivery. Caller frees
/// the returned slice via `freeMessages`.
pub fn drainMailbox(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    team: []const u8,
    recipient: []const u8,
) ![]MailboxMessage {
    const messages = try readMailbox(allocator, cwd, team, recipient);
    errdefer freeMessages(allocator, messages);

    if (messages.len == 0) return messages;

    // Truncate by re-creating the file empty. Only do this once we have parsed
    // the contents, so a parse failure does not lose unread messages.
    const path = try inboxPathAlloc(allocator, cwd, team, recipient);
    defer allocator.free(path);
    {
        const file = std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true }) catch |err| switch (err) {
            error.FileNotFound => return messages,
            else => return err,
        };
        file.close(rt.io);
    }
    return messages;
}

/// Serialize one mailbox record as a single newline-terminated JSON object.
/// Caller frees.
fn encodeRecord(
    allocator: std.mem.Allocator,
    from: []const u8,
    text: []const u8,
    summary: []const u8,
    timestamp: i64,
) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("{\"from\":");
    try std.json.Stringify.value(from, .{}, w);
    try w.writeAll(",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll(",\"summary\":");
    try std.json.Stringify.value(summary, .{}, w);
    try w.print(",\"timestamp\":{d}}}\n", .{timestamp});

    return buf.toOwnedSlice();
}

/// Parse a NDJSON inbox body into owned records. Lines that fail to parse are
/// skipped (best-effort), mirroring the reference which logs and continues.
fn parseRecords(allocator: std.mem.Allocator, data: []const u8) ![]MailboxMessage {
    var out = std.array_list.Managed(MailboxMessage).init(allocator);
    errdefer {
        for (out.items) |m| {
            allocator.free(m.from);
            allocator.free(m.text);
            allocator.free(m.summary);
        }
        out.deinit();
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        const msg = parseRecordLine(allocator, line) catch continue;
        try out.append(msg);
    }

    return out.toOwnedSlice();
}

fn parseRecordLine(allocator: std.mem.Allocator, line: []const u8) !MailboxMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;
    // CLAUDE.md ObjectMap rule: take the object by pointer; do not value-copy it.
    const obj = &parsed.value.object;

    var msg = MailboxMessage{
        .from = try allocator.dupe(u8, ""),
        .text = try allocator.dupe(u8, ""),
        .summary = try allocator.dupe(u8, ""),
        .timestamp = 0,
    };
    errdefer {
        allocator.free(msg.from);
        allocator.free(msg.text);
        allocator.free(msg.summary);
    }

    if (jsonGetString(obj, "from")) |v| try helpers.replaceOwned(allocator, &msg.from, v);
    if (jsonGetString(obj, "text")) |v| try helpers.replaceOwned(allocator, &msg.text, v);
    if (jsonGetString(obj, "summary")) |v| try helpers.replaceOwned(allocator, &msg.summary, v);
    if (obj.get("timestamp")) |v| switch (v) {
        .integer => |n| msg.timestamp = n,
        .float => |f| msg.timestamp = @intFromFloat(f),
        else => {},
    };

    return msg;
}

fn jsonGetString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Open `path` for appending, creating it if missing. Mirrors
/// `team.zig`'s `openAppendFile`: `O_APPEND` serializes concurrent writers so
/// two SendMessage calls cannot interleave halves of each other's record.
fn openAppendFile(path: []const u8) !std.Io.File {
    if (@import("builtin").os.tag == .windows) {
        const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .read = true, .truncate = false });
        return file;
    }
    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd = try std_io.openFlagsAlloc(rt.gpa, path, flags, 0o600);
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

const testing = std.testing;

test "writeToMailbox then readMailbox round-trips one record" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeToMailbox(allocator, cwd, "alpha", "bob", "team-lead", "hello bob", "greeting");

    // The inbox file exists at the expected path.
    const inbox = try helpers.workspacePathAlloc(allocator, cwd, "state/messages/alpha/bob.inbox");
    defer allocator.free(inbox);
    try std.Io.Dir.cwd().access(rt.io, inbox, .{});

    const messages = try readMailbox(allocator, cwd, "alpha", "bob");
    defer freeMessages(allocator, messages);
    try testing.expectEqual(@as(usize, 1), messages.len);
    try testing.expectEqualStrings("team-lead", messages[0].from);
    try testing.expectEqualStrings("hello bob", messages[0].text);
    try testing.expectEqualStrings("greeting", messages[0].summary);
    try testing.expect(messages[0].timestamp != 0);
}

test "writeToMailbox appends multiple records in order" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeToMailbox(allocator, cwd, "alpha", "bob", "alice", "first", "");
    try writeToMailbox(allocator, cwd, "alpha", "bob", "alice", "second", "");

    const messages = try readMailbox(allocator, cwd, "alpha", "bob");
    defer freeMessages(allocator, messages);
    try testing.expectEqual(@as(usize, 2), messages.len);
    try testing.expectEqualStrings("first", messages[0].text);
    try testing.expectEqualStrings("second", messages[1].text);
    // An empty summary still round-trips as the empty string.
    try testing.expectEqualStrings("", messages[0].summary);
}

test "readMailbox on a missing inbox returns empty" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const messages = try readMailbox(allocator, cwd, "alpha", "nobody");
    defer freeMessages(allocator, messages);
    try testing.expectEqual(@as(usize, 0), messages.len);
}

test "drainMailbox returns records then empties the inbox" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeToMailbox(allocator, cwd, "alpha", "bob", "alice", "drain me", "");

    const drained = try drainMailbox(allocator, cwd, "alpha", "bob");
    defer freeMessages(allocator, drained);
    try testing.expectEqual(@as(usize, 1), drained.len);
    try testing.expectEqualStrings("drain me", drained[0].text);

    // After draining, the inbox is empty.
    const after = try readMailbox(allocator, cwd, "alpha", "bob");
    defer freeMessages(allocator, after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "messages with special characters survive JSON encoding" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tricky = "line one\nline \"two\" with quotes\tand a tab";
    try writeToMailbox(allocator, cwd, "alpha", "bob", "alice", tricky, "");

    const messages = try readMailbox(allocator, cwd, "alpha", "bob");
    defer freeMessages(allocator, messages);
    try testing.expectEqual(@as(usize, 1), messages.len);
    try testing.expectEqualStrings(tricky, messages[0].text);
}

test "inboxPathAlloc rejects unsafe team and recipient names" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidTeamName, inboxPathAlloc(allocator, "/tmp", "../escape", "bob"));
    try testing.expectError(error.InvalidRecipientName, inboxPathAlloc(allocator, "/tmp", "alpha", "../escape"));
}
