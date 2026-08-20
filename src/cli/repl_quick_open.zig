const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const paths = @import("../core/paths.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

pub const MAX_ITEMS_DEFAULT: usize = 8000;
pub const MAX_PREVIEW_BYTES: usize = 32 * 1024;

pub const Item = struct {
    path: []u8,
};

pub const Data = struct {
    allocator: std.mem.Allocator,
    workspace: []const u8,
    items: []Item,

    pub fn deinit(self: *Data) void {
        for (self.items) |item| self.allocator.free(item.path);
        self.allocator.free(self.items);
    }
};

/// Ranked subset of items whose relative paths match `query` fuzzily,
/// sorted by score (best first). Caller frees the returned slice.
/// When `query` is empty the items are returned in their natural
/// order (git-listed first, then filesystem walk). Scoring uses
/// parse_helpers.fuzzyScore so the Ctrl-P picker, global search, and
/// the inline suggestion overlay all share a single ranking function.
pub fn rankItems(
    allocator: std.mem.Allocator,
    items: []const Item,
    query: []const u8,
    limit: usize,
) ![]Item {
    const Scored = struct { score: i32, item: Item };
    var ranked = std.array_list.Managed(Scored).init(allocator);
    defer ranked.deinit();

    if (query.len == 0) {
        const take = @min(items.len, limit);
        const out = try allocator.alloc(Item, take);
        for (items[0..take], 0..) |it, idx| out[idx] = it;
        return out;
    }

    for (items) |it| {
        if (parse_helpers.fuzzyScore(query, it.path)) |score| {
            try ranked.append(.{ .score = score, .item = it });
        }
    }
    std.sort.pdq(Scored, ranked.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.item.path, b.item.path);
        }
    }.lt);

    const take = @min(ranked.items.len, limit);
    const out = try allocator.alloc(Item, take);
    for (ranked.items[0..take], 0..) |s, idx| out[idx] = s.item;
    return out;
}

pub fn buildData(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    max_items: usize,
) !Data {
    const effective_max = if (max_items == 0) MAX_ITEMS_DEFAULT else max_items;
    const git_items = try collectGitItems(allocator, workspace, effective_max);
    if (git_items) |items| {
        return .{
            .allocator = allocator,
            .workspace = workspace,
            .items = items,
        };
    }

    return .{
        .allocator = allocator,
        .workspace = workspace,
        .items = try collectWalkItems(allocator, workspace, effective_max),
    };
}

pub fn loadPreview(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    rel_path: []const u8,
    max_lines: usize,
) ![]u8 {
    const abs_path = try std.fs.path.resolve(allocator, &.{ workspace, rel_path });
    defer allocator.free(abs_path);

    const stat = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.AccessDenied,
        => return allocator.dupe(u8, "(preview unavailable)"),
        else => return err,
    };
    if (stat.kind != .file) return allocator.dupe(u8, "(preview unavailable)");

    const file = std.Io.Dir.cwd().openFile(rt.io, abs_path, .{}) catch |err| switch (err) {
        error.AccessDenied => return allocator.dupe(u8, "(preview unavailable)"),
        else => return err,
    };
    defer file.close(rt.io);

    const read_len = @min(@as(usize, @intCast(stat.size)), MAX_PREVIEW_BYTES);
    const raw = try allocator.alloc(u8, read_len);
    defer allocator.free(raw);
    const n = try file.readPositionalAll(rt.io, raw, 0);
    const bytes = raw[0..n];

    if (containsBinaryBytes(bytes)) return allocator.dupe(u8, "(binary file)");
    return truncatePreviewText(allocator, bytes, max_lines, stat.size > MAX_PREVIEW_BYTES);
}

pub fn openInEditor(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    rel_path: []const u8,
) ![]u8 {
    return openInEditorAtLine(allocator, workspace, rel_path, null);
}

pub fn openInEditorAtLine(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    rel_path: []const u8,
    line: ?usize,
) ![]u8 {
    const abs_path = try std.fs.path.resolve(allocator, &.{ workspace, rel_path });
    defer allocator.free(abs_path);

    var editor_buf: [256]u8 = undefined;
    const editor = pickEditor(&editor_buf);
    const shell_command = try buildOpenEditorCommand(allocator, editor, abs_path, line);
    defer allocator.free(shell_command);

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "/bin/sh", "-lc", shell_command },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "quick open: could not launch editor ({s}): {s}",
            .{ editor, @errorName(err) },
        );
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const location = if (line) |line_no|
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rel_path, line_no })
    else
        try allocator.dupe(u8, rel_path);
    defer allocator.free(location);

    return switch (result.term) {
        .exited => |code| if (code == 0)
            std.fmt.allocPrint(allocator, "opened {s} in {s}", .{ location, editor })
        else
            std.fmt.allocPrint(allocator, "quick open: editor exited with code {d} ({s})", .{ code, editor }),
        else => std.fmt.allocPrint(allocator, "quick open: editor terminated abnormally ({s})", .{editor}),
    };
}

fn collectGitItems(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    max_items: usize,
) !?[]Item {
    const argv = [_][]const u8{
        "git",
        "-C",
        workspace,
        "ls-files",
        "--cached",
        "--others",
        "--exclude-standard",
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const ignore_patterns = loadIgnorePatterns(allocator, workspace);
    defer freeIgnorePatterns(allocator, ignore_patterns);

    var out = std.array_list.Managed(Item).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item.path);
        out.deinit();
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (matchesIgnorePatterns(line, ignore_patterns)) continue;
        if (seen.contains(line)) continue;

        const owned = try allocator.dupe(u8, line);
        errdefer allocator.free(owned);
        try out.append(.{ .path = owned });
        try seen.put(owned, {});
        if (out.items.len >= max_items) break;
    }

    allocator.free(result.stdout);
    sortItems(out.items);
    return try out.toOwnedSlice();
}

fn collectWalkItems(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    max_items: usize,
) ![]Item {
    const ignore_patterns = loadIgnorePatterns(allocator, workspace);
    defer freeIgnorePatterns(allocator, ignore_patterns);

    var out = std.array_list.Managed(Item).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item.path);
        out.deinit();
    }

    var stack = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (stack.items) |entry| allocator.free(entry);
        stack.deinit();
    }
    try stack.append(try allocator.dupe(u8, ""));

    while (stack.items.len > 0) {
        const rel_dir = stack.items[stack.items.len - 1];
        _ = stack.pop();
        defer allocator.free(rel_dir);

        const dir_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, workspace)
        else
            try std.fs.path.join(allocator, &.{ workspace, rel_dir });
        defer allocator.free(dir_path);

        var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(rt.io);

        var it = dir.iterate();
        while (try it.next(rt.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;

            const rel_path = if (rel_dir.len == 0)
                try allocator.dupe(u8, entry.name)
            else
                try std.fs.path.join(allocator, &.{ rel_dir, entry.name });

            const normalized = if (std.fs.path.sep == '/')
                rel_path
            else
                try normalizeSeparatorsAlloc(allocator, rel_path);
            defer if (normalized.ptr != rel_path.ptr) allocator.free(normalized);

            switch (entry.kind) {
                .directory => {
                    if (shouldSkipDirectory(entry.name, normalized)) {
                        allocator.free(rel_path);
                        continue;
                    }
                    try stack.append(rel_path);
                },
                .file, .sym_link => {
                    if (matchesIgnorePatterns(normalized, ignore_patterns)) {
                        allocator.free(rel_path);
                        continue;
                    }
                    if (std.fs.path.sep == '/') {
                        try out.append(.{ .path = rel_path });
                    } else {
                        const owned = try allocator.dupe(u8, normalized);
                        allocator.free(rel_path);
                        try out.append(.{ .path = owned });
                    }
                    if (out.items.len >= max_items) {
                        sortItems(out.items);
                        return try out.toOwnedSlice();
                    }
                },
                else => allocator.free(rel_path),
            }
        }
    }

    sortItems(out.items);
    return try out.toOwnedSlice();
}

fn sortItems(items: []Item) void {
    std.mem.sort(Item, items, {}, struct {
        fn lessThan(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

fn loadIgnorePatterns(allocator: std.mem.Allocator, workspace: []const u8) [][]u8 {
    const ignore_path = paths.workspaceIgnorePath(allocator, workspace) catch return allocator.alloc([]u8, 0) catch unreachable;
    defer allocator.free(ignore_path);

    const content = std.Io.Dir.cwd().readFileAlloc(rt.io, ignore_path, allocator, .limited(64 * 1024)) catch return allocator.alloc([]u8, 0) catch unreachable;
    defer allocator.free(content);

    var out = std.array_list.Managed([]u8).init(allocator);
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        out.append(allocator.dupe(u8, line) catch continue) catch continue;
    }
    return out.toOwnedSlice() catch allocator.alloc([]u8, 0) catch unreachable;
}

fn freeIgnorePatterns(allocator: std.mem.Allocator, patterns: [][]u8) void {
    for (patterns) |pattern| allocator.free(pattern);
    allocator.free(patterns);
}

fn matchesIgnorePatterns(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matchIgnoreGlob(path, pattern)) return true;
    }
    return false;
}

fn matchIgnoreGlob(path: []const u8, pattern: []const u8) bool {
    if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
        if (std.mem.startsWith(u8, path, pattern)) return true;
        var buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const search = std.fmt.allocPrint(fba.allocator(), "/{s}", .{pattern}) catch return false;
        return std.mem.indexOf(u8, path, search) != null;
    }

    if (pattern.len > 2 and pattern[0] == '*' and pattern[1] == '.') {
        return std.mem.endsWith(u8, path, pattern[1..]);
    }

    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx|
            path[idx + 1 ..]
        else
            path;
        return std.mem.eql(u8, basename, pattern);
    }

    return std.mem.eql(u8, path, pattern);
}

fn shouldSkipDirectory(name: []const u8, rel_path: []const u8) bool {
    if (std.mem.eql(u8, name, ".git")) return true;
    if (std.mem.eql(u8, name, "node_modules")) return true;
    if (std.mem.eql(u8, name, "zig-cache")) return true;
    if (std.mem.eql(u8, name, ".zig-cache")) return true;
    if (std.mem.eql(u8, name, ".zcode")) return true;
    if (std.mem.eql(u8, rel_path, ".git")) return true;
    return false;
}

fn normalizeSeparatorsAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    return out;
}

fn containsBinaryBytes(bytes: []const u8) bool {
    const scan_len = @min(bytes.len, 4096);
    for (bytes[0..scan_len]) |b| {
        if (b == 0) return true;
    }
    return false;
}

fn truncatePreviewText(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_lines: usize,
    truncated_bytes: bool,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var line_count: usize = 0;
    var last_was_space = false;
    var consumed: usize = 0;
    for (bytes) |ch| {
        if (line_count >= max_lines) break;
        consumed += 1;

        switch (ch) {
            '\r' => {},
            '\n' => {
                try out.append('\n');
                line_count += 1;
                last_was_space = false;
            },
            '\t' => {
                try out.appendSlice("    ");
                last_was_space = false;
            },
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    if (!last_was_space) {
                        try out.append(' ');
                        last_was_space = true;
                    }
                    continue;
                }
                try out.append(ch);
                last_was_space = ch == ' ';
            },
        }
    }

    const had_more_content = consumed < bytes.len;
    if (had_more_content or truncated_bytes) {
        if (out.items().len > 0 and out.items()[out.items().len - 1] != '\n') try out.append('\n');
        try out.appendSlice("...");
    }

    return try out.toOwnedSlice();
}

fn pickEditor(buf: *[256]u8) []const u8 {
    if (@import("../core/env.zig").getenv("VISUAL")) |v| {
        if (v.len > 0 and v.len < buf.len) {
            @memcpy(buf[0..v.len], v);
            return buf[0..v.len];
        }
    }
    if (@import("../core/env.zig").getenv("EDITOR")) |e| {
        if (e.len > 0 and e.len < buf.len) {
            @memcpy(buf[0..e.len], e);
            return buf[0..e.len];
        }
    }
    return "vi";
}

fn buildOpenEditorCommand(
    allocator: std.mem.Allocator,
    editor: []const u8,
    abs_path: []const u8,
    line: ?usize,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.appendSlice(editor);

    if (line) |line_no| {
        const basename = editorBaseName(editor);
        if (usesGotoFlag(basename)) {
            const location = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ abs_path, line_no });
            defer allocator.free(location);
            try out.appendSlice(" -g ");
            try appendSingleQuoted(&out, location);
            return try out.toOwnedSlice();
        }

        if (usesPathLineLocation(basename)) {
            const location = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ abs_path, line_no });
            defer allocator.free(location);
            try out.append(' ');
            try appendSingleQuoted(&out, location);
            return try out.toOwnedSlice();
        }

        if (usesLineFlag(basename)) {
            var line_buf: [24]u8 = undefined;
            const line_arg = std.fmt.bufPrint(&line_buf, "+{d}", .{line_no}) catch "+1";
            try out.append(' ');
            try out.appendSlice(line_arg);
            try out.append(' ');
            try appendSingleQuoted(&out, abs_path);
            return try out.toOwnedSlice();
        }

        if (std.mem.eql(u8, basename, "mate")) {
            var line_buf: [32]u8 = undefined;
            const line_arg = std.fmt.bufPrint(&line_buf, "{d}", .{line_no}) catch "1";
            try out.appendSlice(" -l ");
            try out.appendSlice(line_arg);
            try out.append(' ');
            try appendSingleQuoted(&out, abs_path);
            return try out.toOwnedSlice();
        }
    }

    try out.append(' ');
    try appendSingleQuoted(&out, abs_path);
    return try out.toOwnedSlice();
}

fn appendSingleQuoted(out: *std_io.StringBuilder, text: []const u8) !void {
    try out.append('\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice("'\"'\"'");
        } else {
            try out.append(ch);
        }
    }
    try out.append('\'');
}

fn editorBaseName(editor: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, editor, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const token = trimmed[0..end];
    return if (std.mem.lastIndexOfScalar(u8, token, '/')) |idx| token[idx + 1 ..] else token;
}

fn usesGotoFlag(basename: []const u8) bool {
    return std.mem.eql(u8, basename, "code") or
        std.mem.eql(u8, basename, "codium") or
        std.mem.eql(u8, basename, "cursor") or
        std.mem.eql(u8, basename, "windsurf");
}

fn usesPathLineLocation(basename: []const u8) bool {
    return std.mem.eql(u8, basename, "subl") or
        std.mem.eql(u8, basename, "zed") or
        std.mem.eql(u8, basename, "hx") or
        std.mem.eql(u8, basename, "helix");
}

fn usesLineFlag(basename: []const u8) bool {
    return std.mem.eql(u8, basename, "vi") or
        std.mem.eql(u8, basename, "vim") or
        std.mem.eql(u8, basename, "nvim") or
        std.mem.eql(u8, basename, "nano") or
        std.mem.eql(u8, basename, "emacs");
}

const testing = std.testing;

test "matchIgnoreGlob handles extension and basename patterns" {
    try testing.expect(matchIgnoreGlob("src/main.zig", "*.zig"));
    try testing.expect(matchIgnoreGlob("foo/bar/.env", ".env"));
    try testing.expect(!matchIgnoreGlob("src/main.ts", "*.zig"));
}

test "truncatePreviewText preserves line boundaries" {
    const preview = try truncatePreviewText(testing.allocator, "one\ntwo\nthree\n", 2, false);
    defer testing.allocator.free(preview);
    try testing.expectEqualStrings("one\ntwo\n...", preview);
}

test "containsBinaryBytes detects nul" {
    try testing.expect(containsBinaryBytes("abc\x00def"));
    try testing.expect(!containsBinaryBytes("plain text"));
}

test "buildOpenEditorCommand adds goto flag for code-family editors" {
    const command = try buildOpenEditorCommand(testing.allocator, "code --wait", "/tmp/demo.zig", 17);
    defer testing.allocator.free(command);
    try testing.expectEqualStrings("code --wait -g '/tmp/demo.zig:17'", command);
}

test "buildOpenEditorCommand adds line flag for vim-family editors" {
    const command = try buildOpenEditorCommand(testing.allocator, "nvim", "/tmp/has space/demo.zig", 9);
    defer testing.allocator.free(command);
    try testing.expectEqualStrings("nvim +9 '/tmp/has space/demo.zig'", command);
}
