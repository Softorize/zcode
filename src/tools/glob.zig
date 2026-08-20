const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const helpers = @import("helpers.zig");

const testing = std.testing;

/// Result of splitting a pattern into a search-root and a relative
/// glob. Both slices point into the input pattern (no allocation).
pub const GlobBaseSplit = struct {
    base_dir: []const u8,
    relative_pattern: []const u8,
};

/// Ported from claude-code-main/src/utils/glob.ts
/// `extractGlobBaseDirectory`. Given a glob pattern, find the largest
/// static prefix (the part before the first glob metacharacter) and
/// split the pattern into a directory to walk and a relative pattern
/// to match against. Matters for absolute patterns: ripgrep's --glob
/// flag only accepts relative patterns, so calling it with an
/// absolute pattern silently matches nothing.
///
/// Examples:
///   "src/**/*.zig"           -> base="src", rel="**/*.zig"
///   "/abs/path/**/*.zig"     -> base="/abs/path", rel="**/*.zig"
///   "*.zig"                  -> base="", rel="*.zig"
///   "/*.txt"                 -> base="/", rel="*.txt"
///   "src/main.zig"           -> base="src", rel="main.zig" (no metachars)
///   "main.zig"               -> base="", rel="main.zig"
pub fn extractGlobBaseDirectory(pattern: []const u8) GlobBaseSplit {
    // No metachar = literal path: split on the last separator.
    const glob_meta_idx = std.mem.indexOfAny(u8, pattern, "*?[{") orelse {
        const sep_idx = std.mem.lastIndexOfAny(u8, pattern, "/\\");
        if (sep_idx) |idx| {
            return .{
                .base_dir = pattern[0..idx],
                .relative_pattern = pattern[idx + 1 ..],
            };
        }
        return .{ .base_dir = "", .relative_pattern = pattern };
    };

    // The metachar tells us where the glob piece starts. Everything
    // before the final separator in the static prefix is the search
    // root; everything after is part of the relative pattern.
    const static_prefix = pattern[0..glob_meta_idx];
    const last_sep = std.mem.lastIndexOfAny(u8, static_prefix, "/\\");

    if (last_sep == null) {
        // Metachar appears before any separator: the whole pattern is
        // a single path segment like "*.zig", relative to the caller's
        // cwd.
        return .{ .base_dir = "", .relative_pattern = pattern };
    }

    const sep_idx = last_sep.?;
    var base = static_prefix[0..sep_idx];
    const relative = pattern[sep_idx + 1 ..];

    // Root-directory pattern ("/foo*.txt"): after trimming, base would
    // be empty; retain "/" so the search walks from the root.
    if (base.len == 0 and sep_idx == 0) {
        base = pattern[0..1]; // "/" or "\\"
    }

    return .{ .base_dir = base, .relative_pattern = relative };
}

test "extractGlobBaseDirectory splits relative pattern at first metachar" {
    const got = extractGlobBaseDirectory("src/**/*.zig");
    try testing.expectEqualStrings("src", got.base_dir);
    try testing.expectEqualStrings("**/*.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory splits absolute pattern" {
    const got = extractGlobBaseDirectory("/Users/toto/zig-code/src/**/*.zig");
    try testing.expectEqualStrings("/Users/toto/zig-code/src", got.base_dir);
    try testing.expectEqualStrings("**/*.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory handles bare filename glob" {
    const got = extractGlobBaseDirectory("*.zig");
    try testing.expectEqualStrings("", got.base_dir);
    try testing.expectEqualStrings("*.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory handles root-directory pattern" {
    const got = extractGlobBaseDirectory("/*.txt");
    try testing.expectEqualStrings("/", got.base_dir);
    try testing.expectEqualStrings("*.txt", got.relative_pattern);
}

test "extractGlobBaseDirectory handles literal path with no metachar" {
    const got = extractGlobBaseDirectory("src/main.zig");
    try testing.expectEqualStrings("src", got.base_dir);
    try testing.expectEqualStrings("main.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory handles literal basename" {
    const got = extractGlobBaseDirectory("main.zig");
    try testing.expectEqualStrings("", got.base_dir);
    try testing.expectEqualStrings("main.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory handles brace expansion" {
    const got = extractGlobBaseDirectory("src/{core,tools}/*.zig");
    try testing.expectEqualStrings("src", got.base_dir);
    try testing.expectEqualStrings("{core,tools}/*.zig", got.relative_pattern);
}

test "extractGlobBaseDirectory handles question-mark glob" {
    const got = extractGlobBaseDirectory("src/foo?.zig");
    try testing.expectEqualStrings("src", got.base_dir);
    try testing.expectEqualStrings("foo?.zig", got.relative_pattern);
}

test "glob returns results or unavailable message" {
    const result = try glob(testing.allocator, ".", "*.zig", "src", 10);
    defer testing.allocator.free(result);
    // Either finds files or reports rg not installed.
    try testing.expect(result.len > 0);
}

test "sortByMtimeAndClip orders newest file first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Create three files. Backdate the first two so "new.txt" has
    // the most recent mtime.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "oldest.txt", .data = "a\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "middle.txt", .data = "b\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "new.txt", .data = "c\n" });

    {
        const f = try tmp.dir.openFile(rt.io, "oldest.txt", .{ .mode = .read_write });
        defer f.close(rt.io);
        const two_days_ago: i128 = clock.nowNanos() - 2 * std.time.ns_per_s * 24 * 60 * 60;
        f.setTimestamps(rt.io, .{ .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(two_days_ago) } }, .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(two_days_ago) } } }) catch {};
    }
    {
        const f = try tmp.dir.openFile(rt.io, "middle.txt", .{ .mode = .read_write });
        defer f.close(rt.io);
        const one_day_ago: i128 = clock.nowNanos() - 1 * std.time.ns_per_s * 24 * 60 * 60;
        f.setTimestamps(rt.io, .{ .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(one_day_ago) } }, .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(one_day_ago) } } }) catch {};
    }

    // Feed the output in reverse-mtime order to prove the sort
    // rearranges it.
    const fake_raw = "oldest.txt\nmiddle.txt\nnew.txt\n";
    const sorted = try sortByMtimeAndClip(testing.allocator, cwd, fake_raw, 10);
    defer testing.allocator.free(sorted);

    const new_idx = std.mem.indexOf(u8, sorted, "new.txt") orelse unreachable;
    const middle_idx = std.mem.indexOf(u8, sorted, "middle.txt") orelse unreachable;
    const oldest_idx = std.mem.indexOf(u8, sorted, "oldest.txt") orelse unreachable;
    // newest first
    try testing.expect(new_idx < middle_idx);
    try testing.expect(middle_idx < oldest_idx);
}

test "sortByMtimeAndClip emits a count header on the result" {
    // Pin the new "Found N matching files" header so regressions
    // don't silently drop the scope hint back to the old bare-paths
    // format. The test verifies both the count and the fact that
    // the paths themselves still follow the header.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "alpha.zig", .data = "a\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "beta.zig", .data = "b\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "gamma.zig", .data = "c\n" });

    const sorted = try sortByMtimeAndClip(
        testing.allocator,
        cwd,
        "alpha.zig\nbeta.zig\ngamma.zig\n",
        10,
    );
    defer testing.allocator.free(sorted);

    try testing.expect(std.mem.indexOf(u8, sorted, "Found 3 matching files") != null);
    try testing.expect(std.mem.indexOf(u8, sorted, "alpha.zig") != null);
    try testing.expect(std.mem.indexOf(u8, sorted, "beta.zig") != null);
    try testing.expect(std.mem.indexOf(u8, sorted, "gamma.zig") != null);

    // Header line comes before any of the paths.
    const header_idx = std.mem.indexOf(u8, sorted, "Found").?;
    const alpha_idx = std.mem.indexOf(u8, sorted, "alpha.zig").?;
    try testing.expect(header_idx < alpha_idx);
}

test "sortByMtimeAndClip header uses singular form for one match" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "only.zig", .data = "x\n" });

    const sorted = try sortByMtimeAndClip(testing.allocator, cwd, "only.zig\n", 10);
    defer testing.allocator.free(sorted);

    try testing.expect(std.mem.indexOf(u8, sorted, "Found 1 matching file") != null);
    // The pluralized form must NOT appear.
    try testing.expect(std.mem.indexOf(u8, sorted, "Found 1 matching files") == null);
}

test "sortByMtimeAndClip header reports showing-top-N when truncated" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const names = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig", "e.zig" };
    for (names) |n| try tmp.dir.writeFile(rt.io, .{ .sub_path = n, .data = "x\n" });

    const sorted = try sortByMtimeAndClip(
        testing.allocator,
        cwd,
        "a.zig\nb.zig\nc.zig\nd.zig\ne.zig\n",
        2,
    );
    defer testing.allocator.free(sorted);

    try testing.expect(std.mem.indexOf(u8, sorted, "Found 5 matching files (showing top 2") != null);
    try testing.expect(std.mem.indexOf(u8, sorted, "3 more files truncated") != null);
}

test "sortByMtimeAndClip emits zero-match header for empty input" {
    const cwd = ".";
    const sorted = try sortByMtimeAndClip(testing.allocator, cwd, "", 10);
    defer testing.allocator.free(sorted);
    try testing.expectEqualStrings("Found 0 matching files", sorted);
}

test "sortByMtimeAndClip caps at max_lines and reports truncation count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Create five files; cap at 2.
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" };
    for (names) |n| try tmp.dir.writeFile(rt.io, .{ .sub_path = n, .data = "x\n" });

    const sorted = try sortByMtimeAndClip(testing.allocator, cwd, "a.txt\nb.txt\nc.txt\nd.txt\ne.txt\n", 2);
    defer testing.allocator.free(sorted);

    // 2 kept + truncation notice
    try testing.expect(std.mem.indexOf(u8, sorted, "3 more files truncated") != null);
    // Truncation message now includes the narrow-down nudge from
    // the reference so the model knows HOW to recover.
    try testing.expect(std.mem.indexOf(u8, sorted, "Consider using a more specific path or pattern") != null);
    // After the header ("Found 5 matching files (showing top 2 ...)\n")
    // the body has two path lines before the `...` truncation marker.
    // Search between the newline after the header and the `...` marker.
    const header_end = std.mem.indexOfScalar(u8, sorted, '\n').?;
    const lines_before_truncation = std.mem.indexOf(u8, sorted, "...") orelse sorted.len;
    var newline_count: usize = 0;
    for (sorted[header_end + 1 .. lines_before_truncation]) |b| {
        if (b == '\n') newline_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), newline_count);
}

test "glob rejects a nonexistent search_path with a helpful cwd-aware error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Use an absolute path that definitely doesn't exist so we bypass
    // the "." short-circuit and hit the validation branch. Note that
    // we deliberately don't depend on ripgrep being available here --
    // the validation runs BEFORE the rg spawn.
    const result = try glob(testing.allocator, cwd, "*.txt", "/definitely-not-a-real-path-xyzzy", 10);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "directory does not exist") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/definitely-not-a-real-path-xyzzy") != null);
    // Should surface the cwd so the model can immediately try a
    // path relative to where it actually is.
    try testing.expect(std.mem.indexOf(u8, result, cwd) != null);
}

test "glob rejects a regular file passed as search_path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "not-a-dir.txt", .data = "hello" });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try glob(testing.allocator, cwd, "*.txt", "not-a-dir.txt", 10);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "path is not a directory") != null);
    try testing.expect(std.mem.indexOf(u8, result, "not-a-dir.txt") != null);
    // Includes the actionable hint: use Grep for file-content search.
    try testing.expect(std.mem.indexOf(u8, result, "Grep") != null);
}

test "glob dot path short-circuits the validation check" {
    // The default search_path "." means cwd. Validation is skipped
    // so a caller doesn't need rg + statFile + the full path
    // resolution dance for every call.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "a.txt", .data = "hi" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // If rg isn't available the test exits cleanly via the "unavailable"
    // error path; otherwise we get a real match.
    const result = try glob(testing.allocator, cwd, "*.txt", ".", 10);
    defer testing.allocator.free(result);
    // Either "a.txt" is in the result (rg available) or the unavailable
    // message, but in no case should the output mention "directory
    // does not exist".
    try testing.expect(std.mem.indexOf(u8, result, "directory does not exist") == null);
}

pub fn glob(allocator: std.mem.Allocator, cwd: []const u8, pattern: []const u8, search_path: []const u8, max_results: usize) ![]u8 {
    // Tilde expansion for both the pattern and the search_path.
    // Without this, `~/Documents/**/*.zig` is literally walked as
    // `./~/Documents/**/*.zig` and returns nothing -- the screenshot
    // bug report where zcode couldn't find its own source.
    const expanded_pattern = try helpers.expandHomeTilde(allocator, pattern);
    defer allocator.free(expanded_pattern);
    const expanded_search_path = try helpers.expandHomeTilde(allocator, search_path);
    defer allocator.free(expanded_search_path);

    // Absolute patterns can't be passed as-is to `rg -g` because the
    // --glob flag treats its argument as relative to the search root.
    // Split the pattern into a base directory + relative pattern and
    // rebase the search to the base directory, matching the reference
    // glob.ts behaviour at claude-code-main/src/utils/glob.ts:73-93.
    var effective_pattern: []const u8 = expanded_pattern;
    var effective_search_path: []const u8 = expanded_search_path;

    if (std.fs.path.isAbsolute(pattern)) {
        const split = extractGlobBaseDirectory(pattern);
        if (split.base_dir.len > 0) {
            effective_search_path = split.base_dir;
            effective_pattern = split.relative_pattern;
        }
    }

    // Validate the effective search path BEFORE spawning rg. The
    // reference GlobTool's validateInput runs the same check. Without
    // it, a bad path leaks a cryptic rg error like
    //   "rg: /nonexistent: No such file or directory (os error 2)"
    // and the model wastes a round trip parsing that. With the check,
    // we emit a clean "directory does not exist: X" + cwd hint so
    // the model can immediately try a path the user actually meant.
    //
    // Skip validation when search_path is "." (the default) since
    // that's always the cwd and always exists.
    if (!std.mem.eql(u8, effective_search_path, ".")) {
        // Resolve relative paths against cwd so we stat the same
        // directory rg would eventually walk.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&path_buf);
        const resolved = std.fs.path.resolve(fba.allocator(), &.{ cwd, effective_search_path }) catch effective_search_path;

        const stat = std.Io.Dir.cwd().statFile(rt.io, resolved, .{}) catch |err| switch (err) {
            error.FileNotFound, error.BadPathName, error.NameTooLong => {
                return std.fmt.allocPrint(
                    allocator,
                    "glob failed: directory does not exist: {s}. Current working directory is {s}. Use an absolute path or a path relative to cwd.",
                    .{ effective_search_path, cwd },
                );
            },
            error.AccessDenied => {
                return std.fmt.allocPrint(
                    allocator,
                    "glob failed: permission denied: {s}",
                    .{effective_search_path},
                );
            },
            else => return std.fmt.allocPrint(
                allocator,
                "glob failed: cannot stat {s}: {s}",
                .{ effective_search_path, @errorName(err) },
            ),
        };

        if (stat.kind != .directory) {
            return std.fmt.allocPrint(
                allocator,
                "glob failed: path is not a directory: {s} (kind={s}). Pass a directory path; use Grep for file-content search.",
                .{ effective_search_path, @tagName(stat.kind) },
            );
        }
    }

    const argv = [_][]const u8{
        "rg",
        "--files",
        "-g",
        effective_pattern,
        effective_search_path,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "glob unavailable: ripgrep (rg) is not installed"),
        else => return err,
    };
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 1) {
        // Exit code 1 = no matches found (not an error)
        allocator.free(result.stdout);
        return allocator.dupe(u8, "no matches found");
    }
    if (!(result.term == .exited and result.term.exited == 0)) {
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        const msg = if (stderr_trimmed.len > 0)
            try std.fmt.allocPrint(allocator, "glob error: {s}", .{stderr_trimmed})
        else
            try allocator.dupe(u8, "glob error: unknown failure");
        allocator.free(result.stdout);
        return msg;
    }
    defer allocator.free(result.stdout);

    // Sort matches by modification time descending so the most
    // recently-touched files win the first N slots after clipping.
    // Matches claude-code-main/src/tools/GlobTool/prompt.ts which
    // explicitly promises "Returns matching file paths sorted by
    // modification time". Without the sort, the model would see
    // whatever order rg emitted, which for large result sets is
    // rarely the most useful first-N.
    return try sortByMtimeAndClip(allocator, cwd, result.stdout, @max(@as(usize, 1), max_results));
}

/// Sort newline-separated file paths by mtime descending, then clip
/// to the first `max_lines` entries and rejoin with newlines. Best-
/// effort: paths that fail to stat keep their mtime as 0 and sort
/// to the end so a transient error on one file doesn't kill the
/// entire result set.
fn sortByMtimeAndClip(allocator: std.mem.Allocator, cwd: []const u8, raw_output: []const u8, max_lines: usize) ![]u8 {
    const Entry = struct {
        path: []const u8,
        mtime: i128,
    };

    var entries = std.array_list.Managed(Entry).init(allocator);
    defer entries.deinit();

    var cwd_dir = std.Io.Dir.cwd().openDir(rt.io, cwd, .{}) catch null;
    defer if (cwd_dir) |*dir| dir.close(rt.io);

    var lines = std.mem.splitScalar(u8, raw_output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var mtime: i128 = 0;
        if (cwd_dir) |*dir| {
            if (dir.statFile(rt.io, line, .{})) |st| {
                mtime = st.mtime.toNanoseconds();
            } else |_| {}
        }
        try entries.append(.{ .path = line, .mtime = mtime });
    }

    // Newest first. Zero-mtime (stat failed) ends up at the tail.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.mtime > b.mtime;
        }
    }.lt);

    const take = @min(entries.items.len, max_lines);
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    // Header: tell the model exactly how many matches it has before
    // the path list. Ports the "Found N matching files" summary from
    // claude-code-main/src/tools/GlobTool. Previously a Glob result
    // was just newline-separated paths with no indication of total
    // count, so the model had to count lines (or infer from context)
    // to know whether it got 5 matches or 500.
    if (entries.items.len == 0) {
        try out.writer().writeAll("Found 0 matching files");
    } else if (entries.items.len == 1) {
        try out.writer().writeAll("Found 1 matching file (sorted by mtime, newest first):\n");
    } else if (entries.items.len <= max_lines) {
        try out.writer().print("Found {d} matching files (sorted by mtime, newest first):\n", .{entries.items.len});
    } else {
        try out.writer().print("Found {d} matching files (showing top {d}, sorted by mtime, newest first):\n", .{ entries.items.len, take });
    }

    for (entries.items[0..take], 0..) |e, i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice(e.path);
    }
    if (entries.items.len > take) {
        // Match the reference's truncation message which tells the
        // model HOW to fix the overflow rather than just noting it.
        // "Consider using a more specific path or pattern" is a
        // direct action cue that reliably gets the model to narrow
        // down on the next call.
        try out.writer().print(
            "\n... ({d} more files truncated. Results are truncated. Consider using a more specific path or pattern.)",
            .{entries.items.len - take},
        );
    }
    return out.toOwnedSlice();
}
