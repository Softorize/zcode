const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");

/// Maximum bytes read per referenced file. Anything larger is
/// truncated with a hint so the model can issue a targeted Read
/// call if it needs more. This mirrors the 256 KiB cap the Read
/// tool uses -- we don't want `@huge-log.txt` to blow the request
/// budget just because the user typo'd a filename they thought
/// was small.
pub const MAX_FILE_BYTES: usize = 256 * 1024;

/// Absolute per-request cap on how many @file references we will
/// expand. Ported from claude-code-main/src/utils/mentions/
/// parseAtMentions.ts which bounds expansion to prevent a message
/// like `@a @b @c ... @z` from silently pulling in 26 files.
pub const MAX_REFS_PER_MESSAGE: usize = 25;

/// Result of preprocessing a user message for `@path` file
/// references. If any references were found and expanded, `rewritten`
/// is an allocated copy of the prompt with inlined file blocks
/// prepended. If no references were found (or all were skipped
/// because the path didn't resolve), `rewritten` is null and the
/// caller should use the original prompt unchanged.
pub const Expansion = struct {
    rewritten: ?[]u8,
    expanded_count: usize,
    skipped_count: usize,

    pub fn deinit(self: *Expansion, allocator: std.mem.Allocator) void {
        if (self.rewritten) |r| allocator.free(r);
        self.rewritten = null;
    }
};

/// Preprocess `prompt` for `@path` file references. Ports the
/// @-mention feature from claude-code-main/src/utils/mentions/
/// parseAtMentions.ts:
///
///   - Walks the prompt looking for `@` tokens that form a valid
///     file path (letters/digits/dot/slash/dash/underscore).
///   - Skips tokens that look like email addresses (anything with
///     a second `@` or preceded by `[a-z0-9]` immediately before).
///   - Resolves each path against `cwd`. Files outside the
///     workspace are silently dropped (not a security issue per
///     se, but the UX goal here is "inline the file the user is
///     looking at in their editor", and files outside cwd are
///     usually references to system paths the model doesn't need).
///   - Reads up to MAX_FILE_BYTES per file. Larger files get a
///     truncation notice.
///   - Caps the total number of expansions at MAX_REFS_PER_MESSAGE.
///   - Prepends a block per expanded file in the form:
///
///     <file path="rel/path">
///     ... contents ...
///     </file>
///
///     followed by the original prompt verbatim (so `@foo.zig` is
///     still visible in the message for the model's benefit).
///
/// Returns the expansion metadata. `expansion.rewritten == null`
/// means there was nothing to expand -- use the original prompt.
pub fn expand(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    prompt: []const u8,
) !Expansion {
    var expansion = Expansion{
        .rewritten = null,
        .expanded_count = 0,
        .skipped_count = 0,
    };

    const refs = try collectRefs(allocator, prompt);
    defer allocator.free(refs);

    if (refs.len == 0) return expansion;

    var blocks = std_io.StringBuilder.init(allocator);
    defer blocks.deinit();

    var seen_count: usize = 0;
    for (refs) |ref| {
        if (expansion.expanded_count + expansion.skipped_count >= MAX_REFS_PER_MESSAGE) break;
        seen_count += 1;

        const resolved = resolveInsideWorkspace(allocator, cwd, ref) catch {
            expansion.skipped_count += 1;
            continue;
        };
        defer allocator.free(resolved);

        const file_contents = readIfExists(allocator, resolved) catch {
            expansion.skipped_count += 1;
            continue;
        };
        const fc = file_contents orelse {
            expansion.skipped_count += 1;
            continue;
        };
        defer allocator.free(fc.bytes);

        try blocks.writer().print("<file path=\"{s}\">\n", .{ref});
        try blocks.writer().writeAll(fc.bytes);
        if (blocks.items().len > 0 and blocks.items()[blocks.items().len - 1] != '\n') {
            try blocks.append('\n');
        }
        if (fc.truncated) {
            try blocks.writer().print(
                "... [truncated at {d} bytes -- use Read with offset/limit for more] ...\n",
                .{MAX_FILE_BYTES},
            );
        }
        try blocks.writer().writeAll("</file>\n\n");
        expansion.expanded_count += 1;
    }

    if (expansion.expanded_count == 0) return expansion;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().writeAll(blocks.items());
    try out.writer().writeAll(prompt);
    expansion.rewritten = try out.toOwnedSlice();
    return expansion;
}

const FileContents = struct { bytes: []u8, truncated: bool };

fn readIfExists(allocator: std.mem.Allocator, abs_path: []const u8) !?FileContents {
    const stat = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound,
        error.BadPathName,
        error.NameTooLong,
        error.AccessDenied,
        => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;

    const file = std.Io.Dir.cwd().openFile(rt.io, abs_path, .{}) catch return null;
    defer file.close(rt.io);

    const total_size = stat.size;
    const read_size = @min(total_size, MAX_FILE_BYTES);
    const bytes = try allocator.alloc(u8, @intCast(read_size));
    errdefer allocator.free(bytes);
    const n = try file.readPositionalAll(rt.io, bytes, 0);

    // Sniff for binary content. @-mentioning a PNG or a zip just
    // clutters the message with replacement characters, so we drop
    // those the same way the Read tool does.
    if (containsBinaryBytes(bytes[0..n])) {
        return null;
    }

    return FileContents{
        .bytes = bytes[0..n],
        .truncated = total_size > MAX_FILE_BYTES,
    };
}

fn containsBinaryBytes(bytes: []const u8) bool {
    const scan_len = @min(bytes.len, 4096);
    var nul_count: usize = 0;
    for (bytes[0..scan_len]) |b| {
        if (b == 0) nul_count += 1;
        if (nul_count >= 1) return true;
    }
    return false;
}

/// Resolve `ref` against `cwd` and ensure the result is inside the
/// workspace. Returns an allocated absolute path on success; errors
/// if the resolved path escapes `cwd` via `..`, is an absolute path
/// outside the workspace, or has any other normalization failure.
///
/// Why the inside-workspace check: `@/etc/passwd` in a message is
/// almost certainly a typo or a prompt-injection attempt. Legit
/// workspace refs are always relative or under cwd.
fn resolveInsideWorkspace(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    ref: []const u8,
) ![]u8 {
    if (ref.len == 0) return error.InvalidPath;
    // Reject absolute paths and `..`-heavy traversals outright.
    if (ref[0] == '/') return error.InvalidPath;

    const joined = try std.fs.path.resolve(allocator, &.{ cwd, ref });
    errdefer allocator.free(joined);

    // The resolved path must start with cwd (with a path separator
    // or be cwd itself). Otherwise the ref used `..` to escape.
    if (!std.mem.startsWith(u8, joined, cwd)) return error.InvalidPath;
    if (joined.len > cwd.len and joined[cwd.len] != '/' and joined[cwd.len] != 0) {
        return error.InvalidPath;
    }
    return joined;
}

/// Walk `prompt` and collect every `@path` token that looks like a
/// file reference. Returned slice is owned by the caller and the
/// strings inside point into `prompt` (so no per-entry free).
fn collectRefs(allocator: std.mem.Allocator, prompt: []const u8) ![][]const u8 {
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < prompt.len) {
        // Find next '@'.
        const at = std.mem.indexOfScalarPos(u8, prompt, i, '@') orelse break;

        // Skip email-style: `foo@bar.com` has an alphanumeric char
        // immediately before the @. Legit file refs come after
        // whitespace, start of string, or punctuation.
        const ok_prev = at == 0 or isBoundary(prompt[at - 1]);
        if (!ok_prev) {
            i = at + 1;
            continue;
        }

        // Scan the token after '@'. Accept letters, digits, and the
        // path chars `/`, `.`, `-`, `_`. Stop at any other byte.
        var end = at + 1;
        while (end < prompt.len and isPathChar(prompt[end])) : (end += 1) {}

        // Token must contain at least one letter/digit -- otherwise
        // `@@` or `@-` style noise slips through.
        if (end == at + 1) {
            i = at + 1;
            continue;
        }

        const token = prompt[at + 1 .. end];

        // Skip email-ish: a second `@` inside the token (e.g.
        // `@user@host`) or a TLD-only pattern.
        if (std.mem.indexOfScalar(u8, token, '@') != null) {
            i = end;
            continue;
        }

        // Require at least one `/` or a known file extension so we
        // don't accidentally match `@username` style mentions. We
        // allow a dotted filename at cwd root (`@main.zig`) too.
        if (hasSlashOrDottedExtension(token)) {
            try out.append(token);
        }
        i = end;
    }

    return out.toOwnedSlice();
}

fn isBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or
        c == '(' or c == '[' or c == '{' or c == ',' or c == ';' or
        c == ':' or c == '"' or c == '\'' or c == '`';
}

fn isPathChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '/' or c == '.' or c == '-' or c == '_';
}

fn hasSlashOrDottedExtension(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '/') != null) return true;
    // Dotted name: `main.zig`, `foo.rs`, `README.md` etc.
    const last_dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
    if (last_dot == 0 or last_dot == token.len - 1) return false;
    // Filter out trailing punctuation like `file.zig.` which dot-scan
    // accepts but shouldn't.
    const after_dot = token[last_dot + 1 ..];
    // The extension must be 1-16 letters/digits -- matches real file
    // extensions and skips `.` heavy version strings.
    if (after_dot.len == 0 or after_dot.len > 16) return false;
    for (after_dot) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) return false;
    }
    return true;
}

// --- Tests ---

const testing = std.testing;

test "expand returns null rewritten when prompt has no @refs" {
    const cwd = ".";
    var exp = try expand(testing.allocator, cwd, "explain the architecture");
    defer exp.deinit(testing.allocator);
    try testing.expect(exp.rewritten == null);
    try testing.expectEqual(@as(usize, 0), exp.expanded_count);
}

test "expand inlines a real file referenced by @path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "notes.md",
        .data = "# Project notes\nThis is a test file.\n",
    });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "look at @notes.md please");
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), exp.expanded_count);
    const rewritten = exp.rewritten.?;
    try testing.expect(std.mem.indexOf(u8, rewritten, "<file path=\"notes.md\">") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "Project notes") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "</file>") != null);
    // Original prompt must still be appended.
    try testing.expect(std.mem.indexOf(u8, rewritten, "look at @notes.md please") != null);
}

test "expand inlines multiple files in one message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "a.txt", .data = "alpha content\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "b.txt", .data = "beta content\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "compare @a.txt and @b.txt");
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), exp.expanded_count);
    const rewritten = exp.rewritten.?;
    try testing.expect(std.mem.indexOf(u8, rewritten, "alpha content") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "beta content") != null);
}

test "expand resolves paths with subdirectories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "src/core");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "src/core/util.zig", .data = "pub fn util() void {}\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "review @src/core/util.zig");
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), exp.expanded_count);
    const rewritten = exp.rewritten.?;
    try testing.expect(std.mem.indexOf(u8, rewritten, "pub fn util") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "src/core/util.zig") != null);
}

test "expand skips email-like @user@host tokens" {
    const cwd = ".";
    var exp = try expand(testing.allocator, cwd, "ping @alice@example.com about the PR");
    defer exp.deinit(testing.allocator);
    // No real file, nothing expanded, nothing skipped-as-file either.
    try testing.expectEqual(@as(usize, 0), exp.expanded_count);
}

test "expand skips @username style mentions without slash or extension" {
    const cwd = ".";
    var exp = try expand(testing.allocator, cwd, "@bob can you review this?");
    defer exp.deinit(testing.allocator);
    try testing.expect(exp.rewritten == null);
}

test "expand refuses to leave the workspace via .. traversal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create the inner workspace and a sibling "secret" file.
    try tmp.dir.createDirPath(rt.io, "workspace");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "workspace/inside.txt", .data = "hi\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "secret.txt", .data = "top-secret\n" });
    const workspace_cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "workspace");
    defer testing.allocator.free(workspace_cwd);

    // @../secret.txt must NOT expand.
    var exp = try expand(testing.allocator, workspace_cwd, "show @../secret.txt");
    defer exp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), exp.expanded_count);
}

test "expand refuses absolute paths" {
    const cwd = ".";
    var exp = try expand(testing.allocator, cwd, "inspect @/etc/passwd");
    defer exp.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), exp.expanded_count);
}

test "expand truncates files larger than MAX_FILE_BYTES" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a file slightly larger than the cap.
    const big_size = MAX_FILE_BYTES + 1024;
    const big = try testing.allocator.alloc(u8, big_size);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, idx| b.* = @intCast(('a' + (idx % 26)));
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "big.txt", .data = big });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "read @big.txt");
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), exp.expanded_count);
    const rewritten = exp.rewritten.?;
    try testing.expect(std.mem.indexOf(u8, rewritten, "truncated at") != null);
}

test "expand drops refs to binary files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A "binary" file is detected by having a NUL byte in the first
    // 4 KiB. Give it enough structure to look like a real binary.
    const bin = [_]u8{ 0x7f, 'E', 'L', 'F', 0, 0, 0, 1, 2, 3, 4 };
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "prog", .data = &bin });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "check @prog");
    defer exp.deinit(testing.allocator);
    // @prog has no extension so it shouldn't even be matched, but
    // if future matching logic changes this should still refuse.
    try testing.expect(exp.rewritten == null);
}

test "expand caps at MAX_REFS_PER_MESSAGE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create MAX_REFS_PER_MESSAGE + 5 small files.
    var buf: [32]u8 = undefined;
    var prompt_buf = std_io.StringBuilder.init(testing.allocator);
    defer prompt_buf.deinit();
    try prompt_buf.writer().writeAll("inspect ");

    var i: usize = 0;
    while (i < MAX_REFS_PER_MESSAGE + 5) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "f{d}.txt", .{i});
        try tmp.dir.writeFile(rt.io, .{ .sub_path = name, .data = "ok\n" });
        try prompt_buf.writer().print(" @{s}", .{name});
    }

    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, prompt_buf.items());
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(MAX_REFS_PER_MESSAGE, exp.expanded_count);
}

test "expand silently ignores nonexistent files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // real file we expect to inline
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "real.txt", .data = "real\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    var exp = try expand(testing.allocator, cwd, "compare @real.txt and @missing.txt");
    defer exp.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), exp.expanded_count);
    try testing.expectEqual(@as(usize, 1), exp.skipped_count);
}

test "hasSlashOrDottedExtension distinguishes filenames from usernames" {
    try testing.expect(hasSlashOrDottedExtension("main.zig"));
    try testing.expect(hasSlashOrDottedExtension("src/core/util.zig"));
    try testing.expect(hasSlashOrDottedExtension("README.md"));
    try testing.expect(hasSlashOrDottedExtension("a.txt"));
    try testing.expect(!hasSlashOrDottedExtension("bob"));
    try testing.expect(!hasSlashOrDottedExtension("mention"));
    // Trailing dot is not a valid extension.
    try testing.expect(!hasSlashOrDottedExtension("weird."));
    // Extension must be alphanumeric.
    try testing.expect(!hasSlashOrDottedExtension("foo.-bad"));
}

test "collectRefs respects boundary rules" {
    const refs = try collectRefs(testing.allocator, "see @src/main.zig and (not alice@example.com) plus @other.md!");
    defer testing.allocator.free(refs);
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("src/main.zig", refs[0]);
    try testing.expectEqualStrings("other.md", refs[1]);
}
