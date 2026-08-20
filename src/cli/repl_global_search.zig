const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const parse_helpers = @import("../core/parse_helpers.zig");

pub const MAX_MATCHES_PER_FILE: usize = 10;
pub const MAX_TOTAL_MATCHES_DEFAULT: usize = 500;
pub const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_PREVIEW_BYTES: usize = 256 * 1024;
pub const PREVIEW_CONTEXT_LINES: usize = 4;

pub const Data = struct {
    allocator: std.mem.Allocator,
    workspace: []const u8,
};

pub const Match = struct {
    path: []u8,
    line: usize,
    text: []u8,
};

pub const Results = struct {
    allocator: std.mem.Allocator,
    items: []Match,
    truncated: bool = false,

    pub fn deinit(self: *Results) void {
        for (self.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.text);
        }
        self.allocator.free(self.items);
    }
};

pub fn search(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    query: []const u8,
    max_total_matches: usize,
) !Results {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) {
        return .{
            .allocator = allocator,
            .items = try allocator.alloc(Match, 0),
            .truncated = false,
        };
    }

    var per_file_buf: [16]u8 = undefined;
    const per_file_str = std.fmt.bufPrint(&per_file_buf, "{d}", .{MAX_MATCHES_PER_FILE}) catch "10";

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{
            "rg",
            "-n",
            "--no-heading",
            "-i",
            "-m",
            per_file_str,
            "-F",
            "-e",
            trimmed,
        },
        .cwd = .{ .path = workspace },
        .stdout_limit = .limited(MAX_OUTPUT_BYTES),
        .stderr_limit = .limited(MAX_OUTPUT_BYTES),
    }) catch |err| switch (err) {
        // ripgrep isn't installed. Fall back to the in-process walker
        // so the feature works on minimal systems, Docker containers,
        // and Windows. The fallback is ASCII-literal + case-insensitive
        // and mirrors ripgrep's output shape for a uniform caller API.
        error.FileNotFound => return searchInProcess(allocator, workspace, trimmed, max_total_matches),
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 1) {
                return .{
                    .allocator = allocator,
                    .items = try allocator.alloc(Match, 0),
                    .truncated = false,
                };
            }
            if (code != 0) return error.RipgrepFailed;
        },
        else => return error.RipgrepFailed,
    }

    const effective_max = if (max_total_matches == 0) MAX_TOTAL_MATCHES_DEFAULT else max_total_matches;

    var items = std.array_list.Managed(Match).init(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
        }
        items.deinit();
    }

    var truncated = false;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        const parsed = parseRipgrepLine(line) orelse continue;
        if (items.items.len >= effective_max) {
            truncated = true;
            break;
        }

        const path = try normalizePathAlloc(allocator, parsed.path);
        errdefer allocator.free(path);

        const text = try allocator.dupe(u8, std.mem.trimStart(u8, parsed.text, " \t"));
        errdefer allocator.free(text);

        try items.append(.{
            .path = path,
            .line = parsed.line,
            .text = text,
        });
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .truncated = truncated,
    };
}

pub fn loadPreview(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    rel_path: []const u8,
    target_line: usize,
    context_lines: usize,
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
    return buildPreviewText(allocator, bytes, target_line, context_lines, stat.size > MAX_PREVIEW_BYTES);
}

const ParsedRipgrepLine = struct {
    path: []const u8,
    line: usize,
    text: []const u8,
};

fn parseRipgrepLine(line: []const u8) ?ParsedRipgrepLine {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;

        var j = i + 1;
        while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
        if (j == i + 1 or j >= line.len or line[j] != ':') continue;

        const line_num = std.fmt.parseInt(usize, line[i + 1 .. j], 10) catch return null;
        return .{
            .path = line[0..i],
            .line = line_num,
            .text = line[j + 1 ..],
        };
    }
    return null;
}

fn normalizePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const trimmed = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    const out = try allocator.dupe(u8, trimmed);
    if (std.fs.path.sep != '/') {
        for (out) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
    }
    return out;
}

fn buildPreviewText(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    target_line: usize,
    context_lines: usize,
    truncated_bytes: bool,
) ![]u8 {
    const start_line = if (target_line > context_lines + 1) target_line - context_lines else 1;
    const end_line = target_line + context_lines;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var current_line: usize = 1;
    var line_start: usize = 0;
    var wrote_any = false;

    var i: usize = 0;
    while (i <= bytes.len) : (i += 1) {
        if (i != bytes.len and bytes[i] != '\n') continue;

        if (current_line >= start_line and current_line <= end_line) {
            try appendPreviewLine(&out, current_line, current_line == target_line, bytes[line_start..i]);
            wrote_any = true;
        }
        if (current_line > end_line) break;

        current_line += 1;
        line_start = i + 1;
    }

    if (!wrote_any) return allocator.dupe(u8, "(preview unavailable)");
    if (truncated_bytes and current_line <= end_line) try out.appendSlice("...\n");
    return try out.toOwnedSlice();
}

fn appendPreviewLine(out: *std_io.StringBuilder, line_no: usize, is_target: bool, raw: []const u8) !void {
    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &prefix_buf,
        "{s}{d: >4} | ",
        .{ if (is_target) ">" else " ", line_no },
    ) catch if (is_target) "> ??? | " else "  ??? | ";
    try out.appendSlice(prefix);
    try appendSanitizedLine(out, raw);
    try out.append('\n');
}

fn appendSanitizedLine(out: *std_io.StringBuilder, raw: []const u8) !void {
    for (raw) |ch| {
        switch (ch) {
            '\r' => {},
            '\t' => try out.appendSlice("    "),
            else => {
                if (ch < 0x20 or ch == 0x7f) {
                    try out.append(' ');
                } else {
                    try out.append(ch);
                }
            },
        }
    }
}

fn containsBinaryBytes(bytes: []const u8) bool {
    const scan_len = @min(bytes.len, 4096);
    for (bytes[0..scan_len]) |b| {
        if (b == 0) return true;
    }
    return false;
}

// ── In-process fallback when ripgrep is unavailable ──────────────────

fn searchInProcess(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    query: []const u8,
    max_total_matches: usize,
) !Results {
    const effective_max = if (max_total_matches == 0) MAX_TOTAL_MATCHES_DEFAULT else max_total_matches;
    var items = std.array_list.Managed(Match).init(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item.path);
            allocator.free(item.text);
        }
        items.deinit();
    }

    // Lowercase the needle once for case-insensitive compare. u8[]
    // allocated so the slice lives across the walker loop.
    var needle_lower = try allocator.alloc(u8, query.len);
    defer allocator.free(needle_lower);
    for (query, 0..) |c, i| needle_lower[i] = std.ascii.toLower(c);

    var dir = try std.Io.Dir.cwd().openDir(rt.io, workspace, .{ .iterate = true });
    defer dir.close(rt.io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var truncated = false;
    while (try walker.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (shouldSkipWalkPath(entry.path)) continue;
        if (items.items.len >= effective_max) {
            truncated = true;
            break;
        }

        // Hard byte cap per file so a massive minified bundle can't
        // balloon memory or wall time.
        const bytes = dir.readFileAlloc(rt.io, entry.path, allocator, .limited(MAX_PREVIEW_BYTES)) catch |err| switch (err) {
            error.FileTooBig,
            error.IsDir,
            error.AccessDenied,
            error.FileNotFound,
            => continue,
            else => return err,
        };
        defer allocator.free(bytes);

        if (containsBinaryBytes(bytes)) continue;

        var file_hits: usize = 0;
        var line_no: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= bytes.len) : (i += 1) {
            if (i != bytes.len and bytes[i] != '\n') continue;
            const line = bytes[line_start..i];
            if (containsIgnoreCaseBytes(line, needle_lower)) {
                if (items.items.len >= effective_max) {
                    truncated = true;
                    break;
                }
                const path = try normalizePathAlloc(allocator, entry.path);
                errdefer allocator.free(path);
                const text = try allocator.dupe(u8, std.mem.trimStart(u8, line, " \t"));
                errdefer allocator.free(text);
                try items.append(.{ .path = path, .line = line_no, .text = text });
                file_hits += 1;
                if (file_hits >= MAX_MATCHES_PER_FILE) break;
            }
            line_no += 1;
            line_start = i + 1;
        }
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(),
        .truncated = truncated,
    };
}

fn shouldSkipWalkPath(rel_path: []const u8) bool {
    const skip_dirs = [_][]const u8{
        ".git/",  ".zig-cache/", "zig-out/",     "node_modules/",
        ".venv/", "venv/",       "__pycache__/", "target/",
        "build/", "dist/",       ".cache/",      ".zcode/",
        ".next/", ".nuxt/",      ".svelte-kit/",
    };
    for (skip_dirs) |d| {
        if (std.mem.startsWith(u8, rel_path, d)) return true;
        // Also detect the directory appearing mid-path (e.g. "vendor/node_modules/x").
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, rel_path, idx, d)) |at| {
            if (at == 0 or rel_path[at - 1] == '/') return true;
            idx = at + 1;
        }
    }
    return false;
}

fn containsIgnoreCaseBytes(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (haystack.len < needle_lower.len) return false;
    const last = haystack.len - needle_lower.len + 1;
    var i: usize = 0;
    while (i < last) : (i += 1) {
        var j: usize = 0;
        while (j < needle_lower.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != needle_lower[j]) break;
        }
        if (j == needle_lower.len) return true;
    }
    return false;
}

// ── Group-by-file presentation ───────────────────────────────────────

pub const FileGroup = struct {
    path: []const u8,
    first_match_index: usize,
    match_count: usize,
};

/// Bucket a Results.items slice into one FileGroup per unique path,
/// preserving source order. The returned slice borrows the path
/// strings from `items`, so callers must keep `results` alive while
/// the groups are in use. Frees are done by freeFileGroups.
pub fn groupByFile(allocator: std.mem.Allocator, items: []const Match) ![]FileGroup {
    var out = std.array_list.Managed(FileGroup).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < items.len) {
        const path = items[i].path;
        var j = i + 1;
        while (j < items.len and std.mem.eql(u8, items[j].path, path)) : (j += 1) {}
        try out.append(.{
            .path = path,
            .first_match_index = i,
            .match_count = j - i,
        });
        i = j;
    }
    return out.toOwnedSlice();
}

pub fn freeFileGroups(allocator: std.mem.Allocator, groups: []FileGroup) void {
    allocator.free(groups);
}

// ── fuzzy rank pass (optional) ───────────────────────────────────────

/// Reorder a match list so files whose path matches `path_query`
/// fuzzily (via parse_helpers.fuzzyScore) come first, preserving
/// original order within a file. `path_query` is applied to the file
/// path, not the match text -- the match text is already
/// substring-matched by the search itself. Useful for combining
/// content search + path filter in one picker.
pub fn rankByPathQuery(
    allocator: std.mem.Allocator,
    items: []const Match,
    path_query: []const u8,
) ![]Match {
    if (path_query.len == 0) {
        const out = try allocator.alloc(Match, items.len);
        for (items, 0..) |m, idx| out[idx] = m;
        return out;
    }

    const Scored = struct { score: i32, original: usize };
    var ranked = std.array_list.Managed(Scored).init(allocator);
    defer ranked.deinit();

    for (items, 0..) |m, idx| {
        if (parse_helpers.fuzzyScore(path_query, m.path)) |score| {
            try ranked.append(.{ .score = score, .original = idx });
        }
    }
    std.sort.pdq(Scored, ranked.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.original < b.original;
        }
    }.lt);

    const out = try allocator.alloc(Match, ranked.items.len);
    for (ranked.items, 0..) |s, idx| out[idx] = items[s.original];
    return out;
}

const testing = std.testing;

test "parseRipgrepLine handles colon in file path" {
    const parsed = parseRipgrepLine("foo:bar.zig:27:const value = 1;").?;
    try testing.expectEqualStrings("foo:bar.zig", parsed.path);
    try testing.expectEqual(@as(usize, 27), parsed.line);
    try testing.expectEqualStrings("const value = 1;", parsed.text);
}

test "buildPreviewText marks the focused line" {
    const preview = try buildPreviewText(testing.allocator, "one\ntwo\nthree\nfour\n", 3, 1, false);
    defer testing.allocator.free(preview);
    try testing.expect(std.mem.indexOf(u8, preview, ">   3 | three") != null);
    try testing.expect(std.mem.indexOf(u8, preview, "    2 | two") != null);
}

test "containsIgnoreCaseBytes is case-insensitive" {
    try testing.expect(containsIgnoreCaseBytes("Hello World", "world"));
    try testing.expect(containsIgnoreCaseBytes("hello WORLD", "world"));
    try testing.expect(!containsIgnoreCaseBytes("hello world", "xyz"));
    // Empty needle short-circuits to true.
    try testing.expect(containsIgnoreCaseBytes("anything", ""));
    // Needle longer than haystack -> false.
    try testing.expect(!containsIgnoreCaseBytes("abc", "abcdef"));
}

test "shouldSkipWalkPath skips common build artifacts" {
    try testing.expect(shouldSkipWalkPath(".git/config"));
    try testing.expect(shouldSkipWalkPath("zig-out/bin/zcode"));
    try testing.expect(shouldSkipWalkPath("node_modules/foo/index.js"));
    try testing.expect(shouldSkipWalkPath("vendor/node_modules/x.js"));
    try testing.expect(!shouldSkipWalkPath("src/main.zig"));
    try testing.expect(!shouldSkipWalkPath("README.md"));
}

test "groupByFile buckets contiguous matches per path" {
    const matches = [_]Match{
        .{ .path = @constCast("a.zig"), .line = 1, .text = @constCast("x") },
        .{ .path = @constCast("a.zig"), .line = 3, .text = @constCast("y") },
        .{ .path = @constCast("b.zig"), .line = 2, .text = @constCast("z") },
    };
    const groups = try groupByFile(testing.allocator, &matches);
    defer freeFileGroups(testing.allocator, groups);
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("a.zig", groups[0].path);
    try testing.expectEqual(@as(usize, 2), groups[0].match_count);
    try testing.expectEqualStrings("b.zig", groups[1].path);
    try testing.expectEqual(@as(usize, 1), groups[1].match_count);
}
