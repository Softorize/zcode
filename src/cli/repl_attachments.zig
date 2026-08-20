const std = @import("std");
const std_io = @import("../core/std_io.zig");

pub const Kind = enum {
    image,
    pasted_text,
};

pub const Entry = struct {
    id: usize,
    kind: Kind,
    path: []u8,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const Store = struct {
    entries: std.array_list.Managed(Entry),
    next_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .entries = std.array_list.Managed(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit();
    }

    pub fn add(self: *Store, allocator: std.mem.Allocator, kind: Kind, path: []const u8) !usize {
        const id = self.next_id;
        self.next_id += 1;
        try self.entries.append(.{
            .id = id,
            .kind = kind,
            .path = try allocator.dupe(u8, path),
        });
        return id;
    }

    pub fn get(self: *const Store, id: usize) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    pub fn find(self: *const Store, kind: Kind, path: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (entry.kind == kind and std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    pub fn ensure(self: *Store, allocator: std.mem.Allocator, kind: Kind, path: []const u8) !usize {
        if (self.find(kind, path)) |entry| return entry.id;
        return self.add(allocator, kind, path);
    }
};

pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    id: ?usize = null,
};

const structured_prefix_image = "<@image:";
const structured_prefix_paste = "<@paste:";
const structured_suffix = ">";

fn tokenStart(text: []const u8, idx: usize) usize {
    var start = @min(idx, text.len);
    while (start > 0 and text[start - 1] != '\n' and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}
    return start;
}

fn tokenEnd(text: []const u8, idx: usize) usize {
    var end = @min(idx, text.len);
    while (end < text.len and text[end] != '\n' and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
    return end;
}

fn attachmentKindForLegacyToken(token: []const u8) ?Kind {
    if (token.len < 2 or token[0] != '@') return null;

    const path = legacyPathForToken(token) orelse return null;

    if (std.mem.indexOf(u8, path, "zcode-pasted-images") != null) return .image;
    if (std.mem.indexOf(u8, path, "zcode-pasted-text") != null) return .pasted_text;
    return null;
}

fn legacyPathForToken(token: []const u8) ?[]const u8 {
    if (token.len < 2 or token[0] != '@') return null;
    if (token.len >= 3 and token[1] == '"' and token[token.len - 1] == '"') {
        return token[2 .. token.len - 1];
    }
    return token[1..];
}

fn parseStructuredToken(token: []const u8) ?struct { kind: Kind, id: usize } {
    var prefix: []const u8 = undefined;
    var kind: Kind = undefined;

    if (std.mem.startsWith(u8, token, structured_prefix_image) and std.mem.endsWith(u8, token, structured_suffix)) {
        prefix = structured_prefix_image;
        kind = .image;
    } else if (std.mem.startsWith(u8, token, structured_prefix_paste) and std.mem.endsWith(u8, token, structured_suffix)) {
        prefix = structured_prefix_paste;
        kind = .pasted_text;
    } else {
        return null;
    }

    if (token.len <= prefix.len + structured_suffix.len) return null;
    const id_text = token[prefix.len .. token.len - structured_suffix.len];
    const id = std.fmt.parseInt(usize, id_text, 10) catch return null;
    if (id == 0) return null;
    return .{ .kind = kind, .id = id };
}

fn findQuotedLegacyTokenAt(text: []const u8, idx: usize) ?Token {
    if (text.len == 0 or idx >= text.len) return null;

    var search_end = idx + 1;
    while (search_end > 0) {
        const at_pos = std.mem.lastIndexOfScalar(u8, text[0..search_end], '@') orelse return null;
        if (at_pos + 1 >= text.len or text[at_pos + 1] != '"') {
            search_end = at_pos;
            continue;
        }
        if (at_pos > 0 and text[at_pos - 1] != '\n' and !std.ascii.isWhitespace(text[at_pos - 1])) {
            search_end = at_pos;
            continue;
        }

        var end = at_pos + 2;
        while (end < text.len and text[end] != '"') : (end += 1) {}
        if (end >= text.len) return null;
        end += 1;

        if (idx < at_pos or idx >= end) {
            search_end = at_pos;
            continue;
        }

        const raw = text[at_pos..end];
        const kind = attachmentKindForLegacyToken(raw) orelse return null;
        return .{
            .kind = kind,
            .start = at_pos,
            .end = end,
            .id = null,
        };
    }

    return null;
}

pub fn tokenAt(text: []const u8, idx: usize) ?Token {
    if (findQuotedLegacyTokenAt(text, idx)) |token| return token;
    if (text.len == 0 or idx >= text.len) return null;
    if (std.ascii.isWhitespace(text[idx])) return null;

    const start = tokenStart(text, idx);
    const end = tokenEnd(text, start);
    const token = text[start..end];

    if (parseStructuredToken(token)) |parsed| {
        return .{
            .kind = parsed.kind,
            .start = start,
            .end = end,
            .id = parsed.id,
        };
    }

    const legacy_kind = attachmentKindForLegacyToken(token) orelse return null;
    return .{
        .kind = legacy_kind,
        .start = start,
        .end = end,
        .id = null,
    };
}

pub fn tokenBeforeCursor(text: []const u8, cursor: usize) ?Token {
    if (cursor == 0 or text.len == 0) return null;

    var probe = @min(cursor, text.len);
    if (probe > 0 and std.ascii.isWhitespace(text[probe - 1])) {
        probe -= 1;
    }
    if (probe == 0) return null;
    return tokenAt(text, probe - 1);
}

pub fn deleteTokenBeforeCursor(input_text: []const u8, cursor: usize) ?struct { start: usize, end: usize } {
    const token = tokenBeforeCursor(input_text, cursor) orelse return null;
    var end = token.end;
    if (end < input_text.len and input_text[end] == ' ') end += 1;
    return .{ .start = token.start, .end = end };
}

pub fn ordinalForToken(text: []const u8, token_start_idx: usize, kind: Kind) usize {
    var ordinal: usize = 0;
    var idx: usize = 0;
    while (idx < text.len and idx < token_start_idx) {
        if (tokenAt(text, idx)) |token| {
            if (token.kind == kind) ordinal += 1;
            idx = token.end;
            continue;
        }
        idx += 1;
    }
    return ordinal + 1;
}

pub fn buildStructuredToken(out: []u8, kind: Kind, id: usize) []const u8 {
    return switch (kind) {
        .image => std.fmt.bufPrint(out, "<@image:{d}>", .{id}) catch "",
        .pasted_text => std.fmt.bufPrint(out, "<@paste:{d}>", .{id}) catch "",
    };
}

fn chipLabel(kind: Kind, ordinal: usize, out: []u8) []const u8 {
    const full = switch (kind) {
        .image => std.fmt.bufPrint(out, "Image #{d}", .{ordinal}) catch "",
        .pasted_text => std.fmt.bufPrint(out, "Paste #{d}", .{ordinal}) catch "",
    };
    if (full.len > 0) return full;
    return switch (kind) {
        .image => "Image",
        .pasted_text => "Paste",
    };
}

fn entryLabel(entry: *const Entry, kind: Kind, ordinal: usize, out: []u8) []const u8 {
    const basename = std.fs.path.basename(entry.path);
    if (basename.len > 0) {
        const full = switch (kind) {
            .image => std.fmt.bufPrint(out, "Image #{d} {s}", .{ ordinal, basename }) catch "",
            .pasted_text => std.fmt.bufPrint(out, "Paste #{d} {s}", .{ ordinal, basename }) catch "",
        };
        if (full.len > 0) return full;
    }
    return chipLabel(kind, ordinal, out);
}

pub fn formatDisplayToken(raw_token: []const u8, token: Token, store: ?*const Store, ordinal: usize, out: []u8) []const u8 {
    const width = @min(raw_token.len, out.len);
    if (width == 0) return "";
    if (width == 1) {
        out[0] = '@';
        return out[0..1];
    }
    if (width == 2) {
        out[0] = '[';
        out[1] = ']';
        return out[0..2];
    }

    var label_buf: [96]u8 = undefined;
    const label = blk: {
        if (token.id != null and store != null) {
            if (store.?.get(token.id.?)) |entry| {
                break :blk entryLabel(entry, token.kind, ordinal, label_buf[0..]);
            }
        }
        break :blk chipLabel(token.kind, ordinal, label_buf[0..]);
    };
    const inner = width - 2;
    const used_label = if (label.len > inner) label[0..inner] else label;

    out[0] = '[';
    if (used_label.len > 0) @memcpy(out[1 .. 1 + used_label.len], used_label);
    var fill_start = 1 + used_label.len;
    while (fill_start < width - 1) : (fill_start += 1) {
        out[fill_start] = switch (token.kind) {
            .image => '=',
            .pasted_text => '-',
        };
    }
    out[width - 1] = ']';
    return out[0..width];
}

fn pathNeedsQuotes(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, " \t") != null;
}

fn appendCompiledAttachment(out: *std_io.StringBuilder, entry: *const Entry) !void {
    try out.append('@');
    if (pathNeedsQuotes(entry.path)) try out.append('"');
    try out.appendSlice(entry.path);
    if (pathNeedsQuotes(entry.path)) try out.append('"');
}

pub fn compilePrompt(allocator: std.mem.Allocator, input_text: []const u8, store: *const Store) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < input_text.len) {
        if (tokenAt(input_text, idx)) |token| {
            if (token.start == idx and token.id != null) {
                if (store.get(token.id.?)) |entry| {
                    try appendCompiledAttachment(&out, entry);
                    idx = token.end;
                    continue;
                }
            }
        }
        try out.append(input_text[idx]);
        idx += 1;
    }

    return out.toOwnedSlice();
}

pub fn materializePrompt(allocator: std.mem.Allocator, input_text: []const u8, store: *Store) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < input_text.len) {
        if (tokenAt(input_text, idx)) |token| {
            if (token.start == idx and token.id == null) {
                const raw_token = input_text[token.start..token.end];
                const path = legacyPathForToken(raw_token) orelse {
                    try out.append(input_text[idx]);
                    idx += 1;
                    continue;
                };
                const id = try store.ensure(allocator, token.kind, path);
                var token_buf: [64]u8 = undefined;
                const structured = buildStructuredToken(token_buf[0..], token.kind, id);
                try out.appendSlice(structured);
                idx = token.end;
                continue;
            }
        }
        try out.append(input_text[idx]);
        idx += 1;
    }

    return out.toOwnedSlice();
}

const testing = std.testing;

test "buildStructuredToken and tokenAt round-trip" {
    var token_buf: [32]u8 = undefined;
    const raw = buildStructuredToken(token_buf[0..], .image, 7);
    const token = tokenAt(raw, 2).?;
    try testing.expectEqual(Kind.image, token.kind);
    try testing.expectEqual(@as(?usize, 7), token.id);
}

test "tokenBeforeCursor detects legacy pasted image attachments" {
    const token = tokenBeforeCursor("look @/tmp/zcode-pasted-images/a.png ", "look @/tmp/zcode-pasted-images/a.png ".len).?;
    try testing.expectEqual(Kind.image, token.kind);
    try testing.expectEqual(@as(?usize, null), token.id);
}

test "deleteTokenBeforeCursor includes trailing space for structured token" {
    const text = "x <@paste:4> y";
    const range = deleteTokenBeforeCursor(text, "x <@paste:4> ".len).?;
    try testing.expectEqualStrings("<@paste:4> ", text[range.start..range.end]);
}

test "formatDisplayToken preserves width" {
    var out: [64]u8 = undefined;
    const raw = "<@image:12>";
    const token = tokenAt(raw, 2).?;
    const display = formatDisplayToken(raw, token, null, 2, out[0..]);
    try testing.expectEqual(raw.len, display.len);
    try testing.expectEqual(@as(u8, '['), display[0]);
    try testing.expectEqual(@as(u8, ']'), display[display.len - 1]);
}

test "compilePrompt expands structured attachment tokens to file mentions" {
    var store = Store.init(testing.allocator);
    defer store.deinit(testing.allocator);

    const id = try store.add(testing.allocator, .image, "/tmp/zcode-pasted-images/clip 1.png");
    var token_buf: [32]u8 = undefined;
    const token = buildStructuredToken(token_buf[0..], .image, id);
    const compiled = try compilePrompt(testing.allocator, token, &store);
    defer testing.allocator.free(compiled);

    try testing.expectEqualStrings("@\"/tmp/zcode-pasted-images/clip 1.png\"", compiled);
}

test "materializePrompt converts legacy pasted paths into structured tokens" {
    var store = Store.init(testing.allocator);
    defer store.deinit(testing.allocator);

    const materialized = try materializePrompt(
        testing.allocator,
        "see @\"/tmp/zcode-pasted-images/clip 1.png\" and @/tmp/zcode-pasted-text/note.txt",
        &store,
    );
    defer testing.allocator.free(materialized);

    try testing.expectEqualStrings("see <@image:1> and <@paste:2>", materialized);
    try testing.expectEqualStrings("/tmp/zcode-pasted-images/clip 1.png", store.get(1).?.path);
    try testing.expectEqualStrings("/tmp/zcode-pasted-text/note.txt", store.get(2).?.path);
}
