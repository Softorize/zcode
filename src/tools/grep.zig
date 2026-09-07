const std = @import("std");
const rt = @import("zcode_runtime");
const helpers = @import("helpers.zig");

const testing = std.testing;

/// Ripgrep output modes matching claude-code-main/src/tools/GrepTool/
/// GrepTool.ts output_mode. Each mode is a big context-budget
/// lever for the model:
///
///   .content            Traditional grep output (every matching
///                       line, with optional -A/-B/-C context and
///                       line numbers via -n). Best when the model
///                       needs to reason about the surrounding code.
///   .files_with_matches Just the list of file paths that contain
///                       at least one match (rg -l). Best when the
///                       model is asking "where is X defined?" and
///                       doesn't need the full line -- typically
///                       20x-100x less output for repo-wide greps.
///   .count              One "<path>:<count>" row per file (rg -c).
///                       Best for "how common is this pattern?"
///                       surveys.
///
/// zcode previously only supported .content, so a model question
/// like "find every file that imports X" forced a .content grep
/// that burned context on line text the model didn't care about.
pub const OutputMode = enum {
    content,
    files_with_matches,
    count,

    pub fn fromString(s: []const u8) OutputMode {
        if (std.ascii.eqlIgnoreCase(s, "files_with_matches") or
            std.ascii.eqlIgnoreCase(s, "files-with-matches") or
            std.ascii.eqlIgnoreCase(s, "files") or
            std.ascii.eqlIgnoreCase(s, "-l"))
            return .files_with_matches;
        if (std.ascii.eqlIgnoreCase(s, "count") or
            std.ascii.eqlIgnoreCase(s, "-c"))
            return .count;
        // Everything else (including empty, "content", "-n", ...)
        // falls back to content mode so old callers keep working.
        return .content;
    }
};

test "grep finds pattern in source" {
    const result = try grep(testing.allocator, ".", "pub fn main", "src", 5, false, false, 0, "", "", .content, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    // If rg is not installed, we get an "unavailable" message instead of matches.
    // Only assert content when rg is actually available.
    if (std.mem.indexOf(u8, result, "unavailable") == null) {
        try testing.expect(std.mem.indexOf(u8, result, "main") != null);
    }
}

test "grep returns no matches or error for nonexistent pattern" {
    const result = try grep(testing.allocator, ".", "ZZZZNONEXISTENT999", "src", 5, false, false, 0, "", "", .content, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    // Either "no matches" or rg error message.
    try testing.expect(result.len > 0);
}

test "grep accepts glob filter" {
    const result = try grep(testing.allocator, ".", "pub fn", "src", 5, false, false, 0, "*.zig", "", .content, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

test "grep accepts rg type filter" {
    // rg --type zig filters to just .zig files
    const result = try grep(testing.allocator, ".", "pub fn", "src", 5, false, false, 0, "", "zig", .content, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
}

test "grep files_with_matches mode returns paths only" {
    const result = try grep(testing.allocator, ".", "pub fn main", "src", 5, false, false, 0, "", "", .files_with_matches, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    if (std.mem.indexOf(u8, result, "unavailable") == null and
        std.mem.indexOf(u8, result, "no matches") == null)
    {
        // files_with_matches output lists paths only -- no ":<line>:" prefix
        // that content mode's "-n" would add. If we see ":42:" anywhere, that
        // means we leaked content-mode output into this mode.
        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            // A path-only line won't contain the ":<digits>:" line-number marker.
            // We can't assert the full filename list because test env varies,
            // but we CAN assert there's at least one non-empty line and none of
            // them look like "src/foo.zig:42:content" triple-field rows.
            const first_colon = std.mem.indexOfScalar(u8, line, ':');
            if (first_colon) |idx| {
                if (idx + 2 <= line.len and line[idx + 1] >= '0' and line[idx + 1] <= '9') {
                    try testing.expect(false); // leaked content format
                }
            }
        }
    }
}

test "grep count mode returns file:count pairs" {
    const result = try grep(testing.allocator, ".", "pub fn", "src", 5, false, false, 0, "", "", .count, 0, 0, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(result.len > 0);
    if (std.mem.indexOf(u8, result, "unavailable") == null and
        std.mem.indexOf(u8, result, "no matches") == null)
    {
        // Each non-empty line should match "<path>:<integer>".
        var line_iter = std.mem.splitScalar(u8, result, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse continue;
            const count_part = line[colon + 1 ..];
            _ = std.fmt.parseInt(usize, std.mem.trim(u8, count_part, " \t\r"), 10) catch {
                // Not a valid count suffix -- something's wrong with the parsing.
                try testing.expect(false);
            };
        }
    }
}

test "OutputMode.fromString recognises aliases" {
    try testing.expectEqual(OutputMode.content, OutputMode.fromString(""));
    try testing.expectEqual(OutputMode.content, OutputMode.fromString("content"));
    try testing.expectEqual(OutputMode.files_with_matches, OutputMode.fromString("files_with_matches"));
    try testing.expectEqual(OutputMode.files_with_matches, OutputMode.fromString("files-with-matches"));
    try testing.expectEqual(OutputMode.files_with_matches, OutputMode.fromString("files"));
    try testing.expectEqual(OutputMode.files_with_matches, OutputMode.fromString("-l"));
    try testing.expectEqual(OutputMode.count, OutputMode.fromString("count"));
    try testing.expectEqual(OutputMode.count, OutputMode.fromString("-c"));
    try testing.expectEqual(OutputMode.content, OutputMode.fromString("nonsense"));
}

test "grep rejects a nonexistent absolute path with cwd-aware error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Validation runs BEFORE ripgrep is spawned, so this test
    // works even when rg isn't installed on the host.
    const result = try grep(
        testing.allocator,
        cwd,
        "pattern",
        "/definitely-not-a-real-path-xyzzy",
        10,
        false,
        false,
        0,
        "",
        "",
        .content,
        0,
        0,
        0,
        0,
    );
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "path does not exist") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/definitely-not-a-real-path-xyzzy") != null);
    // Includes the cwd so the model can retry with the right path.
    try testing.expect(std.mem.indexOf(u8, result, cwd) != null);
    // Includes the Glob-first hint.
    try testing.expect(std.mem.indexOf(u8, result, "Glob") != null);
}

test "grep accepts a regular file as search_path (unlike Glob)" {
    // Grep on a single file is legitimate -- ripgrep happily
    // searches just that file. Glob refuses because it needs a
    // directory to walk, but Grep should accept both.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello\npattern match\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Skip if rg isn't installed on the host.
    const result = try grep(
        testing.allocator,
        cwd,
        "pattern",
        "demo.txt",
        10,
        false,
        false,
        0,
        "",
        "",
        .content,
        0,
        0,
        0,
        0,
    );
    defer testing.allocator.free(result);

    // Either rg found the match (real rg installed) or returned
    // the "rg not installed" error. But we should NEVER see the
    // "path does not exist" validation error for a real file.
    try testing.expect(std.mem.indexOf(u8, result, "path does not exist") == null);
}

test "grep dot path short-circuits the validation check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "a.txt", .data = "hi" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try grep(
        testing.allocator,
        cwd,
        "hi",
        ".",
        10,
        false,
        false,
        0,
        "",
        "",
        .content,
        0,
        0,
        0,
        0,
    );
    defer testing.allocator.free(result);

    // The dot short-circuit means we skip the statFile call entirely,
    // so "path does not exist" must never appear regardless of rg
    // availability.
    try testing.expect(std.mem.indexOf(u8, result, "path does not exist") == null);
}

/// Full-featured grep via ripgrep. Matches the subset of
/// claude-code-main/src/tools/GrepTool/GrepTool.ts that fits zcode's
/// sync call model. Parameters:
///
///   pattern          Regex pattern (rg syntax, not POSIX grep)
///   search_path      File or directory to search
///   max_results      Upper bound on matches per file (rg -m)
///   case_insensitive rg -i
///   multiline        rg -U --multiline-dotall
///   context_lines    rg -C
///   glob             Empty for no filter; else rg --glob <pattern>
///                    (e.g. "*.zig", "*.{ts,tsx}")
///   type_filter      Empty for no filter; else rg --type <name>
///                    (e.g. "zig", "py", "rust"). More efficient than
///                    a glob when the caller just wants a language.
///   output_mode      .content -> rg default, lines with matches
///                    .files_with_matches -> rg -l, path list only
///                    .count -> rg -c, per-file match counts
pub fn grep(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    pattern: []const u8,
    search_path: []const u8,
    max_results: usize,
    case_insensitive: bool,
    multiline: bool,
    context_lines: usize,
    glob: []const u8,
    type_filter: []const u8,
    output_mode: OutputMode,
    // tools-20: asymmetric before/after context (rg -B/-A). 0 means "not set" --
    // falls back to the symmetric `context_lines` (-C) when both are 0.
    before_lines: usize,
    after_lines: usize,
    // tools-20: client-side pagination over the combined rg output, mirroring
    // the reference's head_limit/offset. offset skips lines first; head_limit
    // (0 = unlimited) then caps how many of the remaining lines are kept.
    head_limit: usize,
    offset: usize,
) ![]u8 {
    // Tilde expansion: `~/Projects` should map to `$HOME/Projects`
    // before rg ever sees it. Without this, rg walks a literal
    // `./~/Projects` which doesn't exist.
    const expanded_search_path = try helpers.expandHomeTilde(allocator, search_path);
    defer allocator.free(expanded_search_path);

    // Validate the search_path BEFORE spawning rg, same pattern as
    // pass 168's Glob fix. A bad path used to surface as the raw
    // rg stderr ("rg: /nonexistent: No such file or directory
    // (os error 2)"), wasting a round trip while the model tried
    // to figure out whether the problem was the path, the pattern,
    // or ripgrep itself. With the pre-check, we return a clean
    // cwd-aware error so the model can retry with the right path
    // immediately.
    //
    // Unlike Glob (which requires a directory), Grep accepts BOTH
    // files and directories as the search target -- rg happily
    // searches a single file when given one -- so we only reject
    // paths that don't exist at all, not paths that exist but
    // aren't directories.
    //
    // Skip validation when search_path is "." (the default) since
    // that's always cwd and always exists.
    if (!std.mem.eql(u8, expanded_search_path, ".")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&path_buf);
        const resolved = std.fs.path.resolve(fba.allocator(), &.{ cwd, expanded_search_path }) catch expanded_search_path;

        _ = std.Io.Dir.cwd().statFile(rt.io, resolved, .{}) catch |err| switch (err) {
            error.FileNotFound, error.BadPathName, error.NameTooLong => {
                return std.fmt.allocPrint(
                    allocator,
                    "grep failed: path does not exist: {s}. Current working directory is {s}. Use Glob first to find the file, then Grep to search its contents.",
                    .{ search_path, cwd },
                );
            },
            error.AccessDenied => {
                return std.fmt.allocPrint(
                    allocator,
                    "grep failed: permission denied: {s}",
                    .{search_path},
                );
            },
            else => return std.fmt.allocPrint(
                allocator,
                "grep failed: cannot stat {s}: {s}",
                .{ search_path, @errorName(err) },
            ),
        };
    }

    const max_str = try std.fmt.allocPrint(allocator, "{d}", .{@max(@as(usize, 1), max_results)});
    defer allocator.free(max_str);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("rg");
    try argv.append("--no-heading");
    try argv.append("--color");
    try argv.append("never");

    // Mode-specific rg flags. `-n` (line numbers) and `-m` (max
    // matches per file) only make sense in content mode -- in
    // files_with_matches and count mode they either do nothing
    // or actively change the output shape (e.g. rg -l -m 1 is
    // equivalent to -l but costs a flag). Also skip context
    // lines in non-content modes since rg ignores them anyway.
    switch (output_mode) {
        .content => {
            try argv.append("-n");
            try argv.append("-m");
            try argv.append(max_str);
        },
        .files_with_matches => try argv.append("-l"),
        .count => try argv.append("-c"),
    }

    if (case_insensitive) try argv.append("-i");
    if (multiline) {
        try argv.append("-U"); // multiline mode
        try argv.append("--multiline-dotall"); // dot matches newline
    }
    if (glob.len > 0) {
        try argv.append("--glob");
        try argv.append(glob);
    }
    if (type_filter.len > 0) {
        try argv.append("--type");
        try argv.append(type_filter);
    }
    // Allocate at function scope so it survives until Child.run consumes argv.
    // tools-20: -A/-B take priority when either is set (asymmetric context);
    // otherwise fall back to the symmetric -C from `context_lines`.
    var before_buf: [20]u8 = undefined;
    var after_buf: [20]u8 = undefined;
    var ctx_buf: [20]u8 = undefined;
    if (output_mode == .content) {
        if (before_lines > 0 or after_lines > 0) {
            if (before_lines > 0) {
                const before_str = std.fmt.bufPrint(&before_buf, "{d}", .{before_lines}) catch "1";
                try argv.append("-B");
                try argv.append(before_str);
            }
            if (after_lines > 0) {
                const after_str = std.fmt.bufPrint(&after_buf, "{d}", .{after_lines}) catch "1";
                try argv.append("-A");
                try argv.append(after_str);
            }
        } else if (context_lines > 0) {
            const ctx_str = std.fmt.bufPrint(&ctx_buf, "{d}", .{context_lines}) catch "1";
            try argv.append("-C");
            try argv.append(ctx_str);
        }
    }
    try argv.append(pattern);
    try argv.append(expanded_search_path);

    const result = std.process.run(allocator, rt.io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "grep unavailable: ripgrep (rg) is not installed"),
        else => return err,
    };
    defer allocator.free(result.stderr);

    if (result.term == .exited and result.term.exited == 1) {
        allocator.free(result.stdout);
        return allocator.dupe(u8, "no matches");
    }
    if (!(result.term == .exited and result.term.exited == 0)) {
        const msg = try std.fmt.allocPrint(allocator, "grep failed\n{s}", .{result.stderr});
        allocator.free(result.stdout);
        return msg;
    }

    if (head_limit == 0 and offset == 0) return result.stdout;
    defer allocator.free(result.stdout);
    return paginateLines(allocator, result.stdout, offset, head_limit);
}

/// tools-20: skip `offset` lines, then keep at most `head_limit` of the
/// remaining ones (0 = unlimited). Operates on the raw newline-delimited
/// rg output regardless of output_mode -- each mode already emits one
/// logical entry per line (a path, a "path:count", or a "path:line:text"
/// match/context row).
fn paginateLines(allocator: std.mem.Allocator, text: []const u8, offset: usize, head_limit: usize) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    var kept: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // splitScalar yields a trailing empty segment when `text` ends with
        // '\n' -- drop it so pagination counts real lines, not that artifact.
        if (line.len == 0 and lines.peek() == null) break;
        if (idx < offset) {
            idx += 1;
            continue;
        }
        if (head_limit > 0 and kept >= head_limit) break;
        try out.appendSlice(line);
        try out.append('\n');
        idx += 1;
        kept += 1;
    }

    return out.toOwnedSlice();
}

test "tools-20: head_limit and offset paginate the combined output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "many.txt", .data = "match 1\nmatch 2\nmatch 3\nmatch 4\nmatch 5\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // No pagination: all 5 lines (content mode, -n prefixes each).
    const all = try grep(testing.allocator, cwd, "match", "many.txt", 10, false, false, 0, "", "", .content, 0, 0, 0, 0);
    defer testing.allocator.free(all);
    if (std.mem.indexOf(u8, all, "unavailable") != null) return; // rg not installed

    var all_lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, all, "\n"), '\n');
    while (it.next()) |_| all_lines += 1;
    try testing.expectEqual(@as(usize, 5), all_lines);

    // head_limit=2: only the first 2 lines survive.
    const limited = try grep(testing.allocator, cwd, "match", "many.txt", 10, false, false, 0, "", "", .content, 0, 0, 2, 0);
    defer testing.allocator.free(limited);
    var limited_lines: usize = 0;
    var it2 = std.mem.splitScalar(u8, std.mem.trimEnd(u8, limited, "\n"), '\n');
    while (it2.next()) |_| limited_lines += 1;
    try testing.expectEqual(@as(usize, 2), limited_lines);
    try testing.expect(std.mem.indexOf(u8, limited, "match 1") != null);
    try testing.expect(std.mem.indexOf(u8, limited, "match 5") == null);

    // offset=3, head_limit=0: skips the first 3, keeps the rest (2 lines).
    const skipped = try grep(testing.allocator, cwd, "match", "many.txt", 10, false, false, 0, "", "", .content, 0, 0, 0, 3);
    defer testing.allocator.free(skipped);
    try testing.expect(std.mem.indexOf(u8, skipped, "match 1") == null);
    try testing.expect(std.mem.indexOf(u8, skipped, "match 4") != null);
}

test "tools-20: -B/-A produce asymmetric context distinct from -C" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ctx.txt", .data = "line1\nline2\nMATCH\nline4\nline5\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // -B=0,-A=2: no lines before, two lines after.
    const after_only = try grep(testing.allocator, cwd, "MATCH", "ctx.txt", 10, false, false, 0, "", "", .content, 0, 2, 0, 0);
    defer testing.allocator.free(after_only);
    if (std.mem.indexOf(u8, after_only, "unavailable") != null) return; // rg not installed
    try testing.expect(std.mem.indexOf(u8, after_only, "line1") == null);
    try testing.expect(std.mem.indexOf(u8, after_only, "line4") != null);
    try testing.expect(std.mem.indexOf(u8, after_only, "line5") != null);
}
