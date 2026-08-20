//! Generic directory/path completion engine (misc-utils-17, phase 16.31).
//!
//! Port of the reference `directoryCompletion.ts`: parse a partial path into a
//! directory + prefix, scan the directory (with a small time-keyed cache), filter
//! entries by prefix, and sort directories first then by the shared autocomplete
//! rank. The REPL dropdown integration beyond the existing `@`-mention path stays a
//! separate UI task; this module delivers the reusable completion core.
//!
//! Notes / divergences:
//! - The reference uses a 500-entry, 5-minute LRU. We use a bounded (CACHE_MAX
//!   entries) time-keyed cache with the same 5-minute TTL. Bounding the entry count
//!   prevents an adversarial caller from growing memory without limit; on overflow
//!   the cache is cleared wholesale (simplest bound that keeps behavior correct --
//!   a stampede just re-scans).
//! - `~` is expanded against $HOME (env.zig); when HOME is unset the `~` is left
//!   verbatim (the subsequent scan simply fails and yields no completions).

const std = @import("std");
const rt = @import("zcode_runtime");
const autocomplete = @import("autocomplete.zig");
const clock = @import("clock.zig");
const env = @import("env.zig");

/// A scanned filesystem entry. `name` and `path` are owned by the slice the
/// scan returns (or by the cache); callers must not free individual entries --
/// free the whole returned slice via `freeEntries`.
pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
};

/// A completion suggestion. `value` is the path the user would insert (relative
/// directory portion + entry name); `display` appends a trailing `/` for dirs.
/// Both are owned by the returned slice; free via `freeSuggestions`.
pub const Suggestion = struct {
    value: []const u8,
    display: []const u8,
    is_dir: bool,
};

const ParsedPath = struct {
    /// Absolute-or-relative directory to scan. Owned by the caller.
    directory: []const u8,
    /// Borrowed slice of the original token (no allocation).
    prefix: []const u8,
};

/// Cap on entries scanned/returned from one directory, matching the reference's
/// 100-entry MVP slice.
const MAX_SCAN_ENTRIES: usize = 100;
/// Default cap on suggestions returned (reference `maxResults = 10`).
pub const DEFAULT_MAX_RESULTS: usize = 10;
/// Cache TTL: 5 minutes, mirroring the reference LRU ttl.
const CACHE_TTL_MS: i64 = 5 * 60 * 1000;
/// Bound on distinct cached directories (the reference LRU max is 500).
const CACHE_MAX: usize = 500;

/// `true` when `token` looks like a filesystem path the user is typing. Mirrors
/// the reference `isPathLikeToken`: `~/`, `/`, `./`, `../`, or the bare `~`, `.`,
/// `..` tokens.
pub fn isPathLikeToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "~/")) return true;
    if (std.mem.startsWith(u8, token, "/")) return true;
    if (std.mem.startsWith(u8, token, "./")) return true;
    if (std.mem.startsWith(u8, token, "../")) return true;
    if (std.mem.eql(u8, token, "~")) return true;
    if (std.mem.eql(u8, token, ".")) return true;
    if (std.mem.eql(u8, token, "..")) return true;
    return false;
}

/// Expand a leading `~` (or `~/`) against $HOME. Returns an allocator-owned slice;
/// when no expansion applies the input is duped unchanged. Caller frees.
fn expandTilde(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    if (token.len == 0 or token[0] != '~') return allocator.dupe(u8, token);
    // Only expand the bare `~` or a `~/...` prefix (not `~user`, unsupported).
    if (token.len != 1 and token[1] != '/') return allocator.dupe(u8, token);

    const home = env.getOwned(allocator, "HOME") catch return allocator.dupe(u8, token);
    defer allocator.free(home);

    if (token.len == 1) return allocator.dupe(u8, home);
    // token is "~/rest"; join home + "rest".
    return std.fs.path.join(allocator, &.{ home, token[2..] });
}

/// Split `token` into a directory to scan and a name prefix to filter on.
/// `base` is the directory used when the token has no directory component
/// (defaults the scan to the working directory). The returned `directory` is
/// allocator-owned; `prefix` borrows from `token`. Caller frees `directory`.
fn parsePartialPath(allocator: std.mem.Allocator, token: []const u8, base: []const u8) !ParsedPath {
    if (token.len == 0) {
        return .{ .directory = try allocator.dupe(u8, base), .prefix = "" };
    }

    const expanded = try expandTilde(allocator, token);
    defer allocator.free(expanded);

    // A trailing slash means "scan this directory, no prefix".
    if (token[token.len - 1] == '/') {
        return .{ .directory = try resolveDir(allocator, expanded, base), .prefix = "" };
    }

    const dir = std.fs.path.dirname(expanded) orelse "";
    const prefix = std.fs.path.basename(token);
    return .{ .directory = try resolveDir(allocator, dir, base), .prefix = prefix };
}

/// Resolve a (possibly empty/relative) directory against `base`. Absolute paths
/// pass through; empty or "." resolves to `base`; relative paths join onto `base`.
fn resolveDir(allocator: std.mem.Allocator, dir: []const u8, base: []const u8) ![]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) return allocator.dupe(u8, base);
    if (std.fs.path.isAbsolute(dir)) return allocator.dupe(u8, dir);
    return std.fs.path.join(allocator, &.{ base, dir });
}

// --- Directory scan cache -------------------------------------------------

const CacheEntry = struct {
    dir: []const u8, // owned key
    entries: []Entry, // owned value (names+paths owned per entry)
    stored_at_ms: i64,
};

var cache_mutex: std.Io.Mutex = .init;
var cache: std.ArrayList(CacheEntry) = .empty;

fn freeCacheEntry(allocator: std.mem.Allocator, ce: *CacheEntry) void {
    allocator.free(ce.dir);
    freeEntries(allocator, ce.entries);
}

/// Clear the directory cache. Exposed for tests and any explicit invalidation.
pub fn clearCache(allocator: std.mem.Allocator) void {
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);
    for (cache.items) |*ce| freeCacheEntry(allocator, ce);
    cache.clearRetainingCapacity();
}

/// Look up a fresh cache entry; returns a deep copy (caller owns) so the cache can
/// be mutated/evicted independently of the returned slice. Null on miss/expired.
fn cacheGet(allocator: std.mem.Allocator, dir: []const u8, now_ms: i64) !?[]Entry {
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);
    var i: usize = 0;
    while (i < cache.items.len) {
        const ce = &cache.items[i];
        if (now_ms - ce.stored_at_ms > CACHE_TTL_MS) {
            // Expired: drop it.
            freeCacheEntry(allocator, ce);
            _ = cache.swapRemove(i);
            continue;
        }
        if (std.mem.eql(u8, ce.dir, dir)) {
            return try dupeEntries(allocator, ce.entries);
        }
        i += 1;
    }
    return null;
}

/// Store a deep copy of `entries` under `dir`. Bounds the cache to CACHE_MAX by
/// clearing it wholesale on overflow (simplest correct bound).
fn cachePut(allocator: std.mem.Allocator, dir: []const u8, entries: []const Entry, now_ms: i64) !void {
    cache_mutex.lock(rt.io) catch {};
    defer cache_mutex.unlock(rt.io);

    if (cache.items.len >= CACHE_MAX) {
        for (cache.items) |*ce| freeCacheEntry(allocator, ce);
        cache.clearRetainingCapacity();
    }

    const dir_owned = try allocator.dupe(u8, dir);
    errdefer allocator.free(dir_owned);
    const entries_owned = try dupeEntries(allocator, entries);
    errdefer freeEntries(allocator, entries_owned);

    try cache.append(allocator, .{
        .dir = dir_owned,
        .entries = entries_owned,
        .stored_at_ms = now_ms,
    });
}

fn dupeEntries(allocator: std.mem.Allocator, entries: []const Entry) ![]Entry {
    const out = try allocator.alloc(Entry, entries.len);
    var made: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < made) : (k += 1) {
            allocator.free(out[k].name);
            allocator.free(out[k].path);
        }
        allocator.free(out);
    }
    for (entries, 0..) |e, idx| {
        const name = try allocator.dupe(u8, e.name);
        errdefer allocator.free(name);
        const path = try allocator.dupe(u8, e.path);
        out[idx] = .{ .name = name, .path = path, .is_dir = e.is_dir };
        made = idx + 1;
    }
    return out;
}

/// Free a slice returned by `scanDirectory`.
pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
    }
    allocator.free(entries);
}

/// Scan `dir` for entries, excluding hidden (dotfile) names, capped at
/// MAX_SCAN_ENTRIES and sorted directories-first then alphabetically. Cached for
/// CACHE_TTL_MS. Returns an allocator-owned slice; free via `freeEntries`. A
/// missing/unreadable directory yields an empty slice (fail-open, matching the
/// reference's `logError` non-fatal contract).
pub fn scanDirectory(allocator: std.mem.Allocator, dir: []const u8) ![]Entry {
    const now_ms = clock.nowMillis();
    if (try cacheGet(allocator, dir, now_ms)) |hit| return hit;

    const scanned = try scanDirectoryUncached(allocator, dir);
    errdefer freeEntries(allocator, scanned);
    // Best-effort cache store; on failure just skip caching.
    cachePut(allocator, dir, scanned, now_ms) catch {};
    return scanned;
}

fn scanDirectoryUncached(allocator: std.mem.Allocator, dir: []const u8) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(allocator);
    errdefer for (list.items) |e| {
        allocator.free(e.name);
        allocator.free(e.path);
    };

    var d = std.Io.Dir.cwd().openDir(rt.io, dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return allocator.alloc(Entry, 0),
        else => return err,
    };
    defer d.close(rt.io);

    var it = d.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue; // skip hidden
        if (list.items.len >= MAX_SCAN_ENTRIES) break;

        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        errdefer allocator.free(path);

        try list.append(allocator, .{
            .name = name,
            .path = path,
            .is_dir = entry.kind == .directory,
        });
    }

    std.mem.sort(Entry, list.items, {}, entryLessThan);
    return list.toOwnedSlice(allocator);
}

/// Directories first, then case-insensitive name order (reference sort).
fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    if (a.is_dir != b.is_dir) return a.is_dir;
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

/// Free a slice returned by `getPathCompletions`.
pub fn freeSuggestions(allocator: std.mem.Allocator, suggestions: []Suggestion) void {
    for (suggestions) |s| {
        allocator.free(s.value);
        allocator.free(s.display);
    }
    allocator.free(suggestions);
}

/// Produce up to `max_results` completion suggestions for the partial path
/// `token`, scanning relative to `base` (typically the working directory).
/// Suggestions are directories-first, then ranked by the shared autocomplete
/// `rank` against the prefix. The returned `value`/`display` carry the original
/// directory portion of the token so the caller can insert them verbatim.
/// Caller frees via `freeSuggestions`.
pub fn getPathCompletions(
    allocator: std.mem.Allocator,
    token: []const u8,
    base: []const u8,
    max_results: usize,
) ![]Suggestion {
    const parsed = try parsePartialPath(allocator, token, base);
    defer allocator.free(parsed.directory);

    const entries = try scanDirectory(allocator, parsed.directory);
    defer freeEntries(allocator, entries);

    // The directory portion of the original token (everything up to and
    // including the last '/'), with a leading "./" stripped so cwd-relative
    // searches insert clean relative paths.
    const dir_portion = blk: {
        const last_slash = std.mem.lastIndexOfScalar(u8, token, '/') orelse break :blk "";
        var portion = token[0 .. last_slash + 1];
        if (std.mem.startsWith(u8, portion, "./")) portion = portion[2..];
        break :blk portion;
    };

    // Filter by case-insensitive prefix, preserving the dirs-first scan order.
    var filtered: std.ArrayList(Entry) = .empty;
    defer filtered.deinit(allocator);
    for (entries) |e| {
        if (startsWithIgnoreCase(e.name, parsed.prefix)) {
            try filtered.append(allocator, e);
        }
    }

    // Rank the filtered names by the shared scorer. rank() preserves a stable
    // relationship for ties, so we keep the dirs-first grouping by ranking dirs
    // and files separately, then concatenating (dirs before files).
    var out: std.ArrayList(Suggestion) = .empty;
    errdefer {
        for (out.items) |s| {
            allocator.free(s.value);
            allocator.free(s.display);
        }
        out.deinit(allocator);
    }

    try appendRanked(allocator, &out, filtered.items, parsed.prefix, dir_portion, true, max_results);
    if (out.items.len < max_results) {
        try appendRanked(allocator, &out, filtered.items, parsed.prefix, dir_portion, false, max_results);
    }

    return out.toOwnedSlice(allocator);
}

/// Rank the subset of `entries` whose `is_dir` matches `want_dirs` by the shared
/// scorer and append the resulting suggestions to `out`, stopping at `max_results`.
fn appendRanked(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Suggestion),
    entries: []const Entry,
    prefix: []const u8,
    dir_portion: []const u8,
    want_dirs: bool,
    max_results: usize,
) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (entries) |e| {
        if (e.is_dir == want_dirs) try names.append(allocator, e.name);
    }
    if (names.items.len == 0) return;

    const ranked = try autocomplete.rank(allocator, prefix, names.items);
    defer allocator.free(ranked);

    for (ranked) |r| {
        if (out.items.len >= max_results) break;
        const value = try std.fmt.allocPrint(allocator, "{s}{s}", .{ dir_portion, r.value });
        errdefer allocator.free(value);
        const display = if (want_dirs)
            try std.fmt.allocPrint(allocator, "{s}/", .{value})
        else
            try allocator.dupe(u8, value);
        try out.append(allocator, .{ .value = value, .display = display, .is_dir = want_dirs });
    }
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (prefix.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

// --- Tests ----------------------------------------------------------------

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

test "isPathLikeToken accepts path-like tokens and rejects words" {
    try testing.expect(isPathLikeToken("~/"));
    try testing.expect(isPathLikeToken("~/Documents"));
    try testing.expect(isPathLikeToken("./"));
    try testing.expect(isPathLikeToken("./src"));
    try testing.expect(isPathLikeToken("../"));
    try testing.expect(isPathLikeToken("/abs"));
    try testing.expect(isPathLikeToken("~"));
    try testing.expect(isPathLikeToken("."));
    try testing.expect(isPathLikeToken(".."));

    try testing.expect(!isPathLikeToken("word"));
    try testing.expect(!isPathLikeToken("foo/bar"));
    try testing.expect(!isPathLikeToken(""));
    try testing.expect(!isPathLikeToken("@mention"));
}

test "scanDirectory lists entries dirs-first and excludes hidden" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "alpha");
    try tmp.dir.createDirPath(rt.io, "beta");
    var f1 = try tmp.dir.createFile(rt.io, "zeta.txt", .{});
    f1.close(rt.io);
    var f2 = try tmp.dir.createFile(rt.io, "middle.txt", .{});
    f2.close(rt.io);
    var fh = try tmp.dir.createFile(rt.io, ".hidden", .{});
    fh.close(rt.io);

    const dir = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(dir);

    clearCache(alloc);
    const entries = try scanDirectory(alloc, dir);
    defer freeEntries(alloc, entries);

    // Two dirs + two files, hidden excluded.
    try testing.expectEqual(@as(usize, 4), entries.len);
    // Dirs come first, alphabetically.
    try testing.expect(entries[0].is_dir);
    try testing.expect(entries[1].is_dir);
    try testing.expectEqualStrings("alpha", entries[0].name);
    try testing.expectEqualStrings("beta", entries[1].name);
    // Then files, alphabetically.
    try testing.expect(!entries[2].is_dir);
    try testing.expect(!entries[3].is_dir);
    try testing.expectEqualStrings("middle.txt", entries[2].name);
    try testing.expectEqualStrings("zeta.txt", entries[3].name);

    clearCache(alloc);
}

test "scanDirectory of a missing directory yields empty (fail-open)" {
    const alloc = testing.allocator;
    clearCache(alloc);
    const entries = try scanDirectory(alloc, "/no/such/path/zcode-test-xyz");
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
    clearCache(alloc);
}

test "getPathCompletions filters by prefix and lists dirs-first" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "src");
    try tmp.dir.createDirPath(rt.io, "scripts");
    var f1 = try tmp.dir.createFile(rt.io, "setup.py", .{});
    f1.close(rt.io);
    var f2 = try tmp.dir.createFile(rt.io, "other.txt", .{});
    f2.close(rt.io);

    const base = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(base);

    clearCache(alloc);
    // Empty prefix lists everything dirs-first.
    {
        const sugs = try getPathCompletions(alloc, "", base, DEFAULT_MAX_RESULTS);
        defer freeSuggestions(alloc, sugs);
        try testing.expectEqual(@as(usize, 4), sugs.len);
        try testing.expect(sugs[0].is_dir);
        try testing.expect(sugs[1].is_dir);
        try testing.expect(!sugs[2].is_dir);
        // Directory display carries a trailing slash.
        try testing.expect(std.mem.endsWith(u8, sugs[0].display, "/"));
    }

    clearCache(alloc);
    // Prefix "s" matches src, scripts, setup.py (dirs first).
    {
        const sugs = try getPathCompletions(alloc, "s", base, DEFAULT_MAX_RESULTS);
        defer freeSuggestions(alloc, sugs);
        try testing.expectEqual(@as(usize, 3), sugs.len);
        try testing.expect(sugs[0].is_dir);
        try testing.expect(sugs[1].is_dir);
        try testing.expect(!sugs[2].is_dir);
        try testing.expectEqualStrings("setup.py", sugs[2].value);
    }

    clearCache(alloc);
}

test "getPathCompletions preserves the directory portion of the token" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "nested");
    var inner = try tmp.dir.openDir(rt.io, "nested", .{});
    defer inner.close(rt.io);
    var f1 = try inner.createFile(rt.io, "child.zig", .{});
    f1.close(rt.io);

    const base = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(base);

    clearCache(alloc);
    // Token "nested/c" -> directory portion "nested/", entry "child.zig".
    const sugs = try getPathCompletions(alloc, "nested/c", base, DEFAULT_MAX_RESULTS);
    defer freeSuggestions(alloc, sugs);
    try testing.expectEqual(@as(usize, 1), sugs.len);
    try testing.expectEqualStrings("nested/child.zig", sugs[0].value);
    clearCache(alloc);
}

test "getPathCompletions strips a leading ./ from the directory portion" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f1 = try tmp.dir.createFile(rt.io, "readme.md", .{});
    f1.close(rt.io);

    const base = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(base);

    clearCache(alloc);
    const sugs = try getPathCompletions(alloc, "./r", base, DEFAULT_MAX_RESULTS);
    defer freeSuggestions(alloc, sugs);
    try testing.expectEqual(@as(usize, 1), sugs.len);
    // The "./" prefix is stripped from the inserted value.
    try testing.expectEqualStrings("readme.md", sugs[0].value);
    clearCache(alloc);
}
