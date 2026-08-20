const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");

/// Context-aware example prompts for the welcome banner. Ported from
/// claude-code-main/src/utils/exampleCommands.ts (condensed version).
///
/// The reference fetches `git log --name-only` for up to 1000 commits,
/// tallies per-file frequency, filters out non-core files (lock
/// manifests, build artifacts, configs, docs) and suggests prompts
/// like "refactor src/foo.zig" or "how does src/foo.zig work?".
///
/// zcode's port keeps the core idea but shrinks the scope:
///   - Only 200 commits (cheaper on cold-cache machines)
///   - Same non-core filter patterns as the reference
///   - Deterministic pick (no random) so the hint is stable across
///     two consecutive banner renders within the same session
///
/// The hint is a best-effort touch: failures return null so the
/// welcome banner falls back to its static "Type your request" tip.
/// Generate an example prompt based on the workspace's recent git
/// history. Returns an owned string with a suggestion like
/// "refactor src/core/format.zig" or null when the workspace is
/// not a git repo, git is unavailable, or every candidate file
/// was filtered out as non-core.
///
/// Caller owns the returned slice (free with `allocator.free`).
pub fn getExamplePrompt(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const argv = [_][]const u8{
        "git",
        "-C",
        cwd,
        "log",
        "-n",
        "200",
        "--pretty=format:",
        "--name-only",
        "--diff-filter=M",
    };

    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(1 * 1024 * 1024),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    if (result.stdout.len == 0) return null;
    var stdout_buf = std_io.StringBuilder.init(allocator);
    defer stdout_buf.deinit();
    stdout_buf.appendSlice(result.stdout) catch return null;

    // Count frequencies per path. Cap at a reasonable number of distinct
    // paths so pathological repos don't blow memory.
    var counts = std.StringHashMap(u32).init(allocator);
    defer {
        var it = counts.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        counts.deinit();
    }

    var lines = std.mem.splitScalar(u8, stdout_buf.items(), '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        if (!isCoreFile(path)) continue;
        if (counts.count() >= 2048) break;

        if (counts.getPtr(path)) |ptr| {
            ptr.* += 1;
        } else {
            const key = allocator.dupe(u8, path) catch continue;
            counts.put(key, 1) catch {
                allocator.free(key);
                continue;
            };
        }
    }

    if (counts.count() == 0) return null;

    // Pick the most frequently modified core file. Ties broken by path
    // lex order so the suggestion is stable across runs.
    var best_path: ?[]const u8 = null;
    var best_count: u32 = 0;
    var it = counts.iterator();
    while (it.next()) |kv| {
        const path = kv.key_ptr.*;
        const count = kv.value_ptr.*;
        if (count > best_count or (count == best_count and best_path != null and std.mem.order(u8, path, best_path.?) == .lt)) {
            best_count = count;
            best_path = path;
        } else if (best_path == null) {
            best_count = count;
            best_path = path;
        }
    }

    const picked = best_path orelse return null;

    // Pick one of a small set of prompt templates. Use the byte sum of
    // the file path as a stable index so the template rotates for
    // different projects but stays put for the same project. The
    // switch is necessary because std.fmt.allocPrint needs a comptime
    // format string -- we can't index into a runtime array of format
    // strings directly.
    var checksum: usize = 0;
    for (picked) |ch| checksum +%= ch;
    return switch (checksum % 5) {
        0 => try std.fmt.allocPrint(allocator, "refactor {s}", .{picked}),
        1 => try std.fmt.allocPrint(allocator, "how does {s} work?", .{picked}),
        2 => try std.fmt.allocPrint(allocator, "write tests for {s}", .{picked}),
        3 => try std.fmt.allocPrint(allocator, "explain {s}", .{picked}),
        else => try std.fmt.allocPrint(allocator, "simplify {s}", .{picked}),
    };
}

/// Return false when `path` matches any of the non-core patterns
/// ported from the reference's NON_CORE_PATTERNS regex list. The
/// filter is byte-wise (no regex engine) because every pattern can
/// be expressed as "starts with", "ends with", or "contains" on
/// simple literals. Matches are case-insensitive on extensions to
/// catch `.MD` / `.Json` / etc.
fn isCoreFile(path: []const u8) bool {
    if (path.len == 0) return false;

    // Basename for suffix-style patterns
    const last_sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    const basename = if (last_sep) |idx| path[idx + 1 ..] else path;

    // Lock / dependency manifests
    const lock_names = [_][]const u8{
        "package-lock.json", "yarn.lock",    "bun.lock",      "bun.lockb",
        "pnpm-lock.yaml",    "Pipfile.lock", "poetry.lock",   "Cargo.lock",
        "Gemfile.lock",      "go.sum",       "composer.lock", "uv.lock",
    };
    for (lock_names) |name| {
        if (std.mem.eql(u8, basename, name)) return false;
    }

    // Generated / build artifact directories
    const bad_dirs = [_][]const u8{
        "dist/",         "build/", "out/",         "target/",
        "node_modules/", ".next/", "__pycache__/",
    };
    for (bad_dirs) |dir| {
        if (std.mem.indexOf(u8, path, dir) != null) return false;
    }

    // Extensions we consider non-core (data / docs / config)
    const bad_exts = [_][]const u8{
        ".json", ".yaml",   ".yml",     ".toml", ".xml", ".ini", ".cfg",       ".conf",
        ".env",  ".lock",   ".txt",     ".md",   ".mdx", ".rst", ".csv",       ".log",
        ".svg",  ".min.js", ".min.css", ".map",  ".pyc", ".pyo", ".generated",
    };
    for (bad_exts) |ext| {
        if (endsWithIgnoreCase(basename, ext)) return false;
    }

    // Config / metadata filenames (no extension needed)
    const bad_config = [_][]const u8{
        "tsconfig",     "jsconfig",       "eslintrc",    "prettierrc",
        "babelrc",      "editorconfig",   "gitignore",   "gitattributes",
        "dockerignore", "npmrc",          "biome",       "vitest.config",
        "jest.config",  "webpack.config", "vite.config", "rollup.config",
    };
    for (bad_config) |needle| {
        if (std.mem.indexOf(u8, basename, needle) != null) return false;
    }

    // Dot-directories that contain only metadata
    const bad_dot_dirs = [_][]const u8{ ".github/", ".vscode/", ".idea/", ".claude/", ".zcode/" };
    for (bad_dot_dirs) |dir| {
        if (std.mem.indexOf(u8, path, dir) != null) return false;
    }

    // Conventional doc filenames (CHANGELOG, LICENSE, CONTRIBUTING, etc)
    const doc_names = [_][]const u8{ "CHANGELOG", "LICENSE", "CONTRIBUTING", "CODEOWNERS", "README" };
    for (doc_names) |name| {
        // Full match or "NAME.ext" match
        if (std.mem.startsWith(u8, basename, name)) {
            const tail = basename[name.len..];
            if (tail.len == 0 or tail[0] == '.') return false;
        }
    }

    return true;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    const tail = haystack[haystack.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "isCoreFile accepts typical source files" {
    try testing.expect(isCoreFile("src/core/format.zig"));
    try testing.expect(isCoreFile("src/main.zig"));
    try testing.expect(isCoreFile("tools/file.ts"));
    try testing.expect(isCoreFile("lib/module.py"));
    try testing.expect(isCoreFile("src/lib.rs"));
}

test "isCoreFile rejects lock manifests" {
    try testing.expect(!isCoreFile("package-lock.json"));
    try testing.expect(!isCoreFile("yarn.lock"));
    try testing.expect(!isCoreFile("Cargo.lock"));
    try testing.expect(!isCoreFile("go.sum"));
    try testing.expect(!isCoreFile("subdir/pnpm-lock.yaml"));
}

test "isCoreFile rejects build / dependency directories" {
    try testing.expect(!isCoreFile("node_modules/react/index.js"));
    try testing.expect(!isCoreFile("dist/bundle.js"));
    try testing.expect(!isCoreFile("build/foo.o"));
    try testing.expect(!isCoreFile("__pycache__/cache.pyc"));
}

test "isCoreFile rejects data and doc extensions" {
    try testing.expect(!isCoreFile("README.md"));
    try testing.expect(!isCoreFile("CHANGELOG.md"));
    try testing.expect(!isCoreFile("data/fixtures.json"));
    try testing.expect(!isCoreFile("config/app.yaml"));
    try testing.expect(!isCoreFile("docs/guide.rst"));
    try testing.expect(!isCoreFile("logo.svg"));
}

test "isCoreFile rejects common config filenames" {
    try testing.expect(!isCoreFile("tsconfig.json"));
    try testing.expect(!isCoreFile("jest.config.js"));
    try testing.expect(!isCoreFile(".gitignore"));
    try testing.expect(!isCoreFile(".editorconfig"));
}

test "isCoreFile rejects metadata dot-directories" {
    try testing.expect(!isCoreFile(".github/workflows/ci.yml"));
    try testing.expect(!isCoreFile(".vscode/settings.json"));
    try testing.expect(!isCoreFile(".claude/agents/foo.md"));
}

test "isCoreFile allows paths containing dot-directory substrings that are not directories" {
    // "dotgithub" is a filename, not a directory segment, so the
    // ".github/" check should not reject it.
    try testing.expect(isCoreFile("src/dotgithub_helper.zig"));
}

test "endsWithIgnoreCase matches regardless of case" {
    try testing.expect(endsWithIgnoreCase("README.MD", ".md"));
    try testing.expect(endsWithIgnoreCase("Test.JSON", ".json"));
    try testing.expect(!endsWithIgnoreCase("file.ts", ".md"));
}
