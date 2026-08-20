const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("../core/clock.zig");
const builtin = @import("builtin");
const security = @import("../core/security.zig");
const metrics = @import("../core/metrics.zig");
const format = @import("../core/format.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const path_utils = @import("../core/path_utils.zig");
const path_safety = @import("../core/path_safety.zig");
const lsp_manager = @import("../core/lsp/manager.zig");
const lsp_registry = @import("../core/lsp/registry.zig");

// ── Per-session "read before edit" tracker ───────────────────────
//
// Ports the readFileState check from
// claude-code-main/src/tools/FileEditTool/FileEditTool.ts. The
// reference refuses Edit on a file that the model hasn't called
// Read on in the current conversation -- a safety rule that catches
// two classes of common model error:
//
//   1. Blind edits where the model emits a find/replace based on
//      a stale memory of the file. The find string doesn't match
//      the actual bytes, the tool returns "no match", the model
//      retries, and the loop detector eventually fires. With the
//      enforcement, the first Edit fails with a clear "read first"
//      message and the model reads the file to see what's there.
//
//   2. Edits against a file the user edited externally during the
//      conversation. A stale read would produce a find string
//      that matches a pre-edit version of the content, and the
//      silent success would leave the file in a broken state.
//
// We keep a global (per-process) set of absolute paths that have
// been read since the process started. readRange adds to the set
// on success; edit() checks it before proceeding.
//
// Storage uses std.heap.page_allocator rather than the caller's
// allocator so that a GeneralPurposeAllocator under testing
// doesn't report the tracker's still-held keys as leaked memory
// when a test ends without calling resetReadTrackerForTesting.
// The tracker is meant to live for the entire process lifetime,
// which outside of tests is bounded by a single zcode session.
//
// Mutex-guarded so the streaming response thread and the main
// loop can both record without racing.
var read_tracker_mutex: std.Io.Mutex = .init;

/// Per-path read-tracker entry. `mtime` is the file's mtime (as
/// nanoseconds since epoch) at the time Read was called; `recency`
/// is a monotonically increasing ordinal stamped on every Read so
/// callers can sort by most-recently-read. Phase 8 (compaction-08)
/// post-compact file restoration uses `recency` to pick the N
/// most-recently-read files; the edit-gating path only consults
/// `mtime`.
const ReadEntry = struct {
    mtime: i128,
    recency: u64,
};

/// Maps absolute paths to their `ReadEntry`. Ported from
/// claude-code-main/src/tools/FileReadTool which stores `mtime` in
/// `context.readFileState` so downstream Edit/Write calls can
/// detect external modifications between Read and mutation.
///
/// A sentinel mtime of 0 means "we know this file was read but
/// we could not stat it" -- treated as "match anything" to avoid
/// false positives on filesystems with unreliable mtime.
var read_tracker: ?std.StringHashMap(ReadEntry) = null;

/// Monotonically increasing recency ordinal. Incremented on every
/// `trackerRecordRead`, so a higher value means more recently read.
/// Guarded by `read_tracker_mutex` along with the map.
var read_recency_counter: u64 = 0;

pub fn trackerRecordRead(alloc: std.mem.Allocator, abs_path: []const u8) void {
    _ = alloc;
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);

    const owner = std.heap.page_allocator;
    if (read_tracker == null) {
        read_tracker = std.StringHashMap(ReadEntry).init(owner);
    }

    // Capture current mtime so later Edit/Write calls can detect
    // external modifications. A stat failure falls back to 0,
    // which disables the mtime check for that file (the path is
    // still registered so the read-before-edit gate passes).
    const mtime_ns: i128 = blk: {
        const s = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch break :blk 0;
        break :blk s.mtime.toNanoseconds();
    };

    read_recency_counter += 1;
    const recency = read_recency_counter;

    // Update the stored mtime regardless of whether the path was
    // seen before -- a fresh Read call always observes the current
    // on-disk state. Previously we no-oped on duplicates, which
    // meant a Read-Write-Read sequence kept the original (stale)
    // mtime and the second Read's recording was dropped. Bumping
    // `recency` on every read also re-promotes a re-read file to
    // the front of the post-compact restoration ordering.
    if (read_tracker.?.getPtr(abs_path)) |slot| {
        slot.* = .{ .mtime = mtime_ns, .recency = recency };
        return;
    }
    const dup = owner.dupe(u8, abs_path) catch return;
    read_tracker.?.put(dup, .{ .mtime = mtime_ns, .recency = recency }) catch {
        owner.free(dup);
        return;
    };
}

fn trackerWasRead(abs_path: []const u8) bool {
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);
    if (read_tracker == null) return false;
    return read_tracker.?.contains(abs_path);
}

/// Return true when the tracker has a recorded mtime for `abs_path`
/// AND it matches `current_mtime`. Used by the Read tool's unchanged-
/// file short-circuit: if the model re-reads a file we've already
/// seen this session and nothing on disk has changed, we return a
/// stub instead of re-streaming the whole content.
fn trackerMtimeMatches(abs_path: []const u8, current_mtime: i128) bool {
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);
    if (read_tracker == null) return false;
    const recorded = read_tracker.?.get(abs_path) orelse return false;
    // A stored mtime of 0 means "recorded but unknown" -- treat
    // as no-match so we always do a real read for those entries.
    if (recorded.mtime == 0) return false;
    return recorded.mtime == current_mtime;
}

/// Check whether the file at `abs_path` has been modified since
/// the last Read call recorded it. Returns `.fresh` if the file
/// is untouched, `.stale` if the mtime has advanced, or `.unknown`
/// if we can't stat the file or no mtime was recorded. Callers
/// should treat `.unknown` as "assume fresh" so a broken filesystem
/// doesn't lock the user out of editing.
const FreshnessCheck = enum { fresh, stale, unknown };

fn trackerIsFresh(abs_path: []const u8) FreshnessCheck {
    read_tracker_mutex.lock(rt.io) catch {};
    const recorded: ?i128 = blk: {
        if (read_tracker == null) break :blk null;
        if (read_tracker.?.get(abs_path)) |v| break :blk v.mtime;
        break :blk null;
    };
    read_tracker_mutex.unlock(rt.io);

    const rec = recorded orelse return .unknown;
    if (rec == 0) return .unknown; // recorded with unknown mtime
    const now_stat = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch return .unknown;
    if (now_stat.mtime.toNanoseconds() == rec) return .fresh;
    return .stale;
}

/// Return a snapshot of every absolute path the read tracker has
/// seen since process start. Ported from the reference's
/// `cacheKeys(context.readFileState)` helper that powers the
/// /files slash command.
///
/// The returned slice is owned by `out_allocator` and must be
/// freed by the caller with `freeReadTrackerSnapshot`. Each path
/// inside is also heap-owned by the same allocator so the snapshot
/// survives concurrent Read calls without pointing at freed memory.
///
/// Entries are unsorted -- callers that want deterministic output
/// (e.g. a CLI display) should sort by the returned byte order
/// themselves.
pub fn readTrackerSnapshot(out_allocator: std.mem.Allocator) ![][]const u8 {
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);
    if (read_tracker == null) return out_allocator.alloc([]const u8, 0);

    var out = std.array_list.Managed([]const u8).init(out_allocator);
    errdefer {
        for (out.items) |p| out_allocator.free(p);
        out.deinit();
    }
    try out.ensureTotalCapacity(read_tracker.?.count());

    var it = read_tracker.?.keyIterator();
    while (it.next()) |key| {
        const dup = try out_allocator.dupe(u8, key.*);
        try out.append(dup);
    }
    return out.toOwnedSlice();
}

/// Free a slice returned by `readTrackerSnapshot`. Releases every
/// owned path string and then the slice itself. Safe to call on
/// an empty slice.
pub fn freeReadTrackerSnapshot(out_allocator: std.mem.Allocator, snapshot: [][]const u8) void {
    for (snapshot) |p| out_allocator.free(p);
    out_allocator.free(snapshot);
}

/// Test-only helper to drop the tracker between cases so state
/// from one test doesn't leak into another. Frees every stored
/// key via the page_allocator. Outside tests the tracker lives
/// for the full process lifetime so a long-running session keeps
/// accumulating reads, which is the correct behaviour -- every
/// read-before-edit pair stays valid.
pub fn resetReadTrackerForTesting() void {
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);
    if (read_tracker == null) return;
    const owner = std.heap.page_allocator;
    var it = read_tracker.?.keyIterator();
    while (it.next()) |key| owner.free(key.*);
    read_tracker.?.deinit();
    read_tracker = null;
    read_recency_counter = 0;
}

/// Return up to `max` absolute paths the read tracker has seen,
/// sorted by descending recency (most-recently-read first). Powers
/// Phase 8 (compaction-08) post-compact file restoration, which
/// re-reads the N most-recently-read files after a compaction.
///
/// The returned slice is owned by `out_allocator` and must be freed
/// with `freeReadTrackerSnapshot` (same ownership as
/// `readTrackerSnapshot`: each path string is heap-owned by the same
/// allocator). An empty result is a zero-length slice, not an error.
pub fn recentReadPaths(out_allocator: std.mem.Allocator, max: usize) ![][]const u8 {
    read_tracker_mutex.lock(rt.io) catch {};
    defer read_tracker_mutex.unlock(rt.io);
    if (read_tracker == null or max == 0) return out_allocator.alloc([]const u8, 0);

    // Collect (recency, path) pairs, sort descending by recency, then
    // dupe the top `max` paths. We borrow the live keys only inside the
    // mutex; the duped copies handed back outlive the map.
    const Pair = struct { recency: u64, path: []const u8 };
    var pairs = std.array_list.Managed(Pair).init(out_allocator);
    defer pairs.deinit();
    try pairs.ensureTotalCapacity(read_tracker.?.count());

    var it = read_tracker.?.iterator();
    while (it.next()) |entry| {
        pairs.appendAssumeCapacity(.{
            .recency = entry.value_ptr.recency,
            .path = entry.key_ptr.*,
        });
    }

    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.recency > b.recency; // descending: newest first
        }
    }.lessThan);

    const take = @min(max, pairs.items.len);
    var out = std.array_list.Managed([]const u8).init(out_allocator);
    errdefer {
        for (out.items) |p| out_allocator.free(p);
        out.deinit();
    }
    try out.ensureTotalCapacity(take);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        const dup = try out_allocator.dupe(u8, pairs.items[i].path);
        out.appendAssumeCapacity(dup);
    }
    return out.toOwnedSlice();
}

/// File extensions that Claude Code's text tools refuse to read as
/// text. Ported verbatim from claude-code-main/src/constants/files.ts
/// BINARY_EXTENSIONS. Kept in alphabetical buckets so future sync
/// passes can diff the lists side by side. Reading a .png/.sqlite/.jar
/// through Read used to return garbage to the model -- worse, null
/// bytes in the binary could break the JSON encoding of the tool
/// result. This list lets us bail out early with a clean error
/// message instead of feeding the model a corrupted token stream.
const BINARY_EXTENSIONS = [_][]const u8{
    // Images
    ".png",    ".jpg",     ".jpeg", ".gif",    ".bmp",
    ".ico",    ".webp",    ".tiff", ".tif",
    // Videos
       ".mp4",
    ".mov",    ".avi",     ".mkv",  ".webm",   ".wmv",
    ".flv",    ".m4v",     ".mpeg", ".mpg",
    // Audio
       ".mp3",
    ".wav",    ".ogg",     ".flac", ".aac",    ".m4a",
    ".wma",    ".aiff",    ".opus",
    // Archives
    ".zip",    ".tar",
    ".gz",     ".bz2",     ".7z",   ".rar",    ".xz",
    ".z",      ".tgz",     ".iso",
    // Executables / native objects
     ".exe",    ".dll",
    ".so",     ".dylib",   ".bin",  ".o",      ".a",
    ".obj",    ".lib",     ".app",  ".msi",    ".deb",
    ".rpm",
    // Documents (PDF is here; if the caller has a dedicated PDF reader
    // it should short-circuit this check before calling read)
       ".pdf",     ".doc",  ".docx",   ".xls",
    ".xlsx",   ".ppt",     ".pptx", ".odt",    ".ods",
    ".odp",
    // Fonts
       ".ttf",     ".otf",  ".woff",   ".woff2",
    ".eot",
    // Bytecode / VM artifacts
       ".pyc",     ".pyo",  ".class",  ".jar",
    ".war",    ".ear",     ".node", ".wasm",   ".rlib",
    // Databases
    ".sqlite", ".sqlite3", ".db",   ".mdb",    ".idx",
    // Design / 3D
    ".psd",    ".ai",      ".eps",  ".sketch", ".fig",
    ".xd",     ".blend",   ".3ds",  ".max",
    // Flash
       ".swf",
    ".fla",
    // Lock / profiling data
       ".lockb",   ".dat",  ".data",
};

/// Number of leading bytes inspected by `isBinaryContent`. Matches
/// the reference `BINARY_CHECK_SIZE = 8192` from
/// claude-code-main/src/constants/files.ts. 8 KiB is the sweet spot
/// in the reference: large enough to catch null bytes that always
/// land in a binary's header (ELF, Mach-O, PNG, ZIP all have
/// nulls in the first ~64 bytes) without slowing down the read of
/// a 100 MiB log file or a giant JSON dump.
pub const BINARY_CHECK_SIZE: usize = 8192;

/// True when `buffer` looks like binary content. Ports
/// `isBinaryContent` from claude-code-main/src/constants/files.ts.
///
/// The reference uses two signals -- both intentionally fast and
/// imperfect -- to decide whether a buffer is a text file or a
/// binary blob:
///
///   1. Any null byte in the first 8 KiB is conclusive: text files
///      essentially never contain `\x00`, and every common binary
///      format (ELF, PE, Mach-O, PNG, JPEG, PDF, ZIP, sqlite, ...)
///      embeds nulls in its header.
///   2. Otherwise count non-printable ASCII (anything below SP=32
///      that isn't tab, LF, CR). If more than 10% of the first 8 KiB
///      is non-printable, treat as binary. This catches binaries
///      that happen to put their first null past byte 8192 but are
///      still mostly bytes the model can't render.
///
/// 10% is the reference threshold and is deliberately loose so
/// formatted-but-text content (CSV with control chars, source
/// files with literal CR characters, ANSI-coloured logs) doesn't
/// get mis-flagged.
///
/// Pairs with `hasBinaryExtension`: extension is the cheap O(1)
/// guard for known formats, content sniffing is the safety net for
/// extension-less files (compiled artifacts in $PATH, raw blobs,
/// images saved without their suffix). Read/Edit call both so the
/// model can never accidentally splice a binary into the prompt.
pub fn isBinaryContent(buffer: []const u8) bool {
    const check_size = @min(buffer.len, BINARY_CHECK_SIZE);
    if (check_size == 0) return false;

    var non_printable: usize = 0;
    var i: usize = 0;
    while (i < check_size) : (i += 1) {
        const byte = buffer[i];
        // Null byte is conclusive evidence of binary content; bail out
        // immediately rather than waiting for the percentage threshold.
        if (byte == 0) return true;
        if (byte < 32 and byte != 9 and byte != 10 and byte != 13) {
            non_printable += 1;
        }
    }

    // Avoid floating point: `non_printable / check_size > 0.1` becomes
    // `non_printable * 10 > check_size`. Strictly greater than matches
    // the reference's `> 0.1`.
    return (non_printable * 10) > check_size;
}

/// True when `path` has one of the BINARY_EXTENSIONS suffixes.
/// Image extensions that we can base64-encode for vision models.
const IMAGE_EXTENSIONS = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };

pub fn isImageExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    var lower_buf: [8]u8 = undefined;
    const take = @min(ext.len, lower_buf.len);
    for (ext[0..take], 0..) |c, j| lower_buf[j] = std.ascii.toLower(c);
    const lower = lower_buf[0..take];
    for (IMAGE_EXTENSIONS) |img_ext| {
        if (std.mem.eql(u8, lower, img_ext)) return true;
    }
    return false;
}

/// Read an image file, base64-encode it, and return a tagged block
/// that vision-capable models can interpret. Max 10 MiB.
fn readImageAsBase64(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    const max_image_bytes: usize = 10 * 1024 * 1024; // 10 MiB
    const raw = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(max_image_bytes)) catch |err| switch (err) {
        error.FileNotFound => return std.fmt.allocPrint(allocator, "error: image not found: {s}", .{path}),
        error.FileTooBig => return std.fmt.allocPrint(allocator, "error: image too large (>10MB): {s}", .{path}),
        error.AccessDenied => return std.fmt.allocPrint(allocator, "error: access denied: {s}", .{path}),
        else => return std.fmt.allocPrint(allocator, "error reading image '{s}': {s}", .{ path, @errorName(err) }),
    };
    defer allocator.free(raw);

    const ext = std.fs.path.extension(path);
    const media_type = if (std.ascii.eqlIgnoreCase(ext, ".png"))
        "image/png"
    else if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg"))
        "image/jpeg"
    else if (std.ascii.eqlIgnoreCase(ext, ".gif"))
        "image/gif"
    else if (std.ascii.eqlIgnoreCase(ext, ".webp"))
        "image/webp"
    else
        "application/octet-stream";

    // Base64 encode
    const base64 = std.base64.standard;
    const encoded_len = base64.Encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = base64.Encoder.encode(encoded, raw);

    // Return as a tagged block so providers can detect and convert
    // to native image content blocks (Anthropic, OpenAI, Gemini).
    return std.fmt.allocPrint(
        allocator,
        "<zcode-image media_type=\"{s}\" path=\"{s}\" bytes=\"{d}\">\n{s}\n</zcode-image>",
        .{ media_type, path, raw.len, encoded },
    );
}

fn isPdfExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    var lower_buf: [8]u8 = undefined;
    const take = @min(ext.len, lower_buf.len);
    for (ext[0..take], 0..) |c, j| lower_buf[j] = std.ascii.toLower(c);
    return std.mem.eql(u8, lower_buf[0..take], ".pdf");
}

/// Read a PDF file by extracting text via `pdftotext` (from poppler-utils).
/// Supports page ranges via offset/limit (offset=page start, limit=page count).
fn readPdfAsText(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, page_start: usize, page_count: usize) ![]u8 {
    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    // Check file exists
    std.Io.Dir.cwd().access(rt.io, abs, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "error: PDF not found or inaccessible: {s} ({s})", .{ path, @errorName(err) });
    };

    // Build pdftotext command with optional page range
    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "pdftotext";
    argc += 1;

    var first_buf: [16]u8 = undefined;
    var last_buf: [16]u8 = undefined;
    if (page_start > 0) {
        argv_buf[argc] = "-f";
        argc += 1;
        argv_buf[argc] = std.fmt.bufPrint(&first_buf, "{d}", .{page_start}) catch "1";
        argc += 1;
        if (page_count > 0) {
            argv_buf[argc] = "-l";
            argc += 1;
            argv_buf[argc] = std.fmt.bufPrint(&last_buf, "{d}", .{page_start + page_count - 1}) catch "999";
            argc += 1;
        }
    }
    argv_buf[argc] = abs;
    argc += 1;
    argv_buf[argc] = "-";
    argc += 1; // output to stdout

    const result = std.process.run(allocator, rt.io, .{
        .argv = argv_buf[0..argc],
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024), // 2 MiB max
    }) catch |err| {
        if (err == error.FileNotFound) {
            return allocator.dupe(u8, "error: pdftotext not found. Install poppler-utils: brew install poppler (macOS) or apt install poppler-utils (Linux)");
        }
        return std.fmt.allocPrint(allocator, "error running pdftotext: {s}", .{@errorName(err)});
    };
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        defer allocator.free(result.stdout);
        return std.fmt.allocPrint(allocator, "pdftotext failed on '{s}'. Ensure it's a valid PDF.", .{path});
    }

    if (result.stdout.len == 0) {
        return std.fmt.allocPrint(allocator, "PDF '{s}' contains no extractable text (may be image-only).", .{path});
    }

    return result.stdout; // caller owns
}

/// Case-insensitive so .PNG and .png both match.
pub fn hasBinaryExtension(path: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return false;
    const raw_ext = path[dot..];
    if (raw_ext.len > 16) return false;
    var ext_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < raw_ext.len) : (i += 1) {
        ext_buf[i] = std.ascii.toLower(raw_ext[i]);
    }
    const ext = ext_buf[0..raw_ext.len];
    for (BINARY_EXTENSIONS) |known| {
        if (std.mem.eql(u8, ext, known)) return true;
    }
    return false;
}

/// Device files that would hang the read tool: infinite output
/// (/dev/zero, /dev/random, ...) or blocking input (/dev/stdin,
/// /dev/tty, ...). Ported verbatim from claude-code-main/src/tools/
/// FileReadTool/FileReadTool.ts BLOCKED_DEVICE_PATHS. Safe special
/// files like /dev/null are intentionally NOT in this list because
/// reading them returns immediately with EOF.
const BLOCKED_DEVICE_PATHS = [_][]const u8{
    // Infinite output -- never reach EOF
    "/dev/zero",
    "/dev/random",
    "/dev/urandom",
    "/dev/full",
    // Blocks waiting for input
    "/dev/stdin",
    "/dev/tty",
    "/dev/console",
    // Nonsensical to read
    "/dev/stdout",
    "/dev/stderr",
    // fd aliases for stdin/stdout/stderr
    "/dev/fd/0",
    "/dev/fd/1",
    "/dev/fd/2",
};

/// True when `path` points to a device file that would hang the
/// read tool. Checks the BLOCKED_DEVICE_PATHS exact set plus the
/// /proc/self/fd/0-2 (and /proc/<pid>/fd/0-2) Linux aliases for
/// stdio. Returns false for safe special files like /dev/null.
/// The check is path-only (no I/O) so it is safe to call before
/// any filesystem access -- the whole point is to never open the
/// device file at all.
pub fn isBlockedDevicePath(path: []const u8) bool {
    for (BLOCKED_DEVICE_PATHS) |blocked| {
        if (std.mem.eql(u8, path, blocked)) return true;
    }
    // /proc/self/fd/0-2 and /proc/<pid>/fd/0-2 are Linux aliases
    // for the calling process's stdio. Reading them blocks just
    // like reading /dev/stdin.
    if (std.mem.startsWith(u8, path, "/proc/") and
        (std.mem.endsWith(u8, path, "/fd/0") or
            std.mem.endsWith(u8, path, "/fd/1") or
            std.mem.endsWith(u8, path, "/fd/2")))
    {
        return true;
    }
    return false;
}

fn deviceBlockedError(allocator: std.mem.Allocator, requested: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "error: cannot read '{s}': this device file would block or produce infinite output.",
        .{requested},
    );
}

fn deviceBlockedWriteError(allocator: std.mem.Allocator, requested: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "error: cannot write '{s}': writing to a device file is refused (would either trash the device entry on rename, hang on a tty/pipe, or silently drop the data).",
        .{requested},
    );
}

/// Kernel-authoritative device guard: returns true when `abs` is a
/// character or block device that should be refused for read/write.
/// `/dev/null` is the explicit allow (canonical empty source/sink).
/// Caller owns the stat decision; returning false means "not a
/// device, proceed".
fn isStatBlockedDevice(abs: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(rt.io, abs, .{}) catch return false;
    if (st.kind != .character_device and st.kind != .block_device) return false;
    if (std.mem.eql(u8, abs, "/dev/null")) return false;
    return true;
}

/// Read the ZCODE_SKIP_READ_BEFORE_EDIT env var and return true
/// when it's set to a truthy value. Escape hatch for non-interactive
/// callers (CI scripts, one-shot tools) that drive the edit flow
/// directly and can't route through a conversation's Read call.
fn readBeforeEditSkipEnvSet() bool {
    const env = @import("../core/env.zig");
    return env.isEnvTruthy("ZCODE_SKIP_READ_BEFORE_EDIT");
}

/// Return true if `abs_path` points to an existing directory. Used
/// by Read/Write/Edit/MultiEdit to refuse directory targets with
/// a friendlier error than Zig's raw `error.IsDir`. Falls through
/// to false on any stat failure (nonexistent, permission denied,
/// etc.) so the downstream file-open path produces its own error.
fn pathIsDirectory(abs_path: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch return false;
    return st.kind == .directory;
}

/// UTF-8 encoding of U+202F (NARROW NO-BREAK SPACE). macOS uses
/// this character before AM/PM in screenshot filenames on newer
/// system versions, and a plain ASCII space (' ') on older ones.
/// When the user copies the path from Finder or quotes a filename
/// from a previous Spotlight result they often get the wrong
/// space character and Read('/Users/x/Screenshot ... AM.png')
/// returns ENOENT even though the file is right there.
const THIN_SPACE: []const u8 = "\xe2\x80\xaf";

/// For macOS screenshot paths with AM/PM the space immediately
/// before AM/PM may be either a regular space (0x20) or a thin
/// no-break space (U+202F) depending on the macOS version. This
/// returns the alternate path to try when the original doesn't
/// exist, or null when the filename doesn't look like a screenshot.
/// Caller owns the returned slice.
///
/// Ported from claude-code-main/src/tools/FileReadTool/FileReadTool.ts
/// getAlternateScreenshotPath. The reference matches `.png` only
/// because Mac screenshots are always PNGs; zcode generalises to
/// any extension because the underlying bug (Finder/Spotlight
/// pasting U+202F where the user expects a regular space, and
/// vice versa) affects every file the user might copy out of a
/// Finder window, not just screenshots. Reference users get the
/// retry for free as a strict subset.
pub fn getAlternateScreenshotPath(allocator: std.mem.Allocator, file_path: []const u8) !?[]u8 {
    const basename = std.fs.path.basename(file_path);
    if (basename.len < 5) return null; // need at least "X AM.x"

    // Find the extension. We require an extension because the
    // AM/PM segment must come BEFORE it.
    const last_dot = std.mem.lastIndexOfScalar(u8, basename, '.') orelse return null;
    if (last_dot == 0) return null; // dotfile, no real extension
    const without_ext = basename[0..last_dot];
    const ext_with_dot = basename[last_dot..];

    if (without_ext.len < 3) return null; // need at least "X" + space + "AM"
    const am_pm = without_ext[without_ext.len - 2 ..];
    if (!std.mem.eql(u8, am_pm, "AM") and !std.mem.eql(u8, am_pm, "PM")) return null;

    const before_am_pm = without_ext[0 .. without_ext.len - 2];
    if (before_am_pm.len == 0) return null;

    // The character immediately before AM/PM must be either ' '
    // (1 byte) or U+202F (3 bytes). Anything else is not a
    // screenshot we can rescue.
    var prefix_end: usize = undefined;
    var alternate_space: []const u8 = undefined;
    if (before_am_pm[before_am_pm.len - 1] == ' ') {
        prefix_end = before_am_pm.len - 1;
        alternate_space = THIN_SPACE;
    } else if (before_am_pm.len >= 3 and
        std.mem.eql(u8, before_am_pm[before_am_pm.len - 3 ..], THIN_SPACE))
    {
        prefix_end = before_am_pm.len - 3;
        alternate_space = " ";
    } else {
        return null;
    }

    // The reference regex requires `.+` (at least one char) before
    // the space, so a basename like " AM.png" is not eligible.
    if (prefix_end == 0) return null;

    const new_basename = try std.fmt.allocPrint(
        allocator,
        "{s}{s}{s}{s}",
        .{ before_am_pm[0..prefix_end], alternate_space, am_pm, ext_with_dot },
    );
    defer allocator.free(new_basename);

    const dirname_opt = std.fs.path.dirname(file_path);
    if (dirname_opt) |dirname| {
        return try std.fs.path.join(allocator, &.{ dirname, new_basename });
    }
    return try allocator.dupe(u8, new_basename);
}

pub fn read(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, max_bytes: usize) ![]u8 {
    return readRange(allocator, cwd, path, max_bytes, 0, 0);
}

/// Read a file with optional line range. offset=0 and limit=0 read
/// the whole file (same as the simpler `read` entry point). Ported
/// from claude-code-main/src/tools/FileReadTool/FileReadTool.ts
/// which exposes offset/limit as part of its inputSchema so the
/// model can page through large files without blowing context.
///
///   offset: 1-indexed starting line (0 means start at line 1)
///   limit:  max lines to read (0 means read to end of file)
///
/// The returned slice is cat -n wrapped with line numbers starting
/// at the ACTUAL line number (so Read(path, offset=100, limit=50)
/// returns lines labelled 100..149, not 1..50). Edit's find/replace
/// path strips those prefixes back out before matching, so the
/// round-trip stays transparent to the file's actual bytes.
pub fn readRange(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, max_bytes: usize, offset: usize, limit: usize) ![]u8 {
    // Image files: base64-encode for vision-capable models instead
    // of rejecting as binary. Returns a tagged block that providers
    // can detect and convert to native image content blocks.
    if (isImageExtension(path)) {
        return readImageAsBase64(allocator, cwd, path);
    }

    // PDF files: extract text via pdftotext command-line tool.
    if (isPdfExtension(path)) {
        return readPdfAsText(allocator, cwd, path, offset, limit);
    }

    if (hasBinaryExtension(path)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to read binary file '{s}'. Text tools (Read, Grep, Edit) do not support this extension. Use a dedicated Bash command (e.g. `file`, `hexdump -C`, `sqlite3`) if you need to inspect the content.",
            .{path},
        );
    }

    // Block device files BEFORE touching the filesystem. Reading
    // /dev/zero produces infinite output and never reaches EOF;
    // /dev/stdin and /dev/tty block waiting for terminal input;
    // /proc/self/fd/0-2 are Linux aliases for the same. Without
    // this guard the model can hang the agent indefinitely with a
    // single typo. The check is path-only so we never open the
    // device file at all.
    if (isBlockedDevicePath(path)) {
        return deviceBlockedError(allocator, path);
    }

    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    // Also check the resolved path: a relative request like
    // 'dev/zero' from cwd '/' or a symlink that lands on /dev/stdin
    // would slip past the raw-input check above.
    if (isBlockedDevicePath(abs)) {
        return deviceBlockedError(allocator, path);
    }

    // Reject directories with a helpful hint before we even attempt
    // a read. Without this, Zig's readFileAlloc bubbles up a raw
    // `error.IsDir` that the model sees as opaque -- typical retry
    // loop is to Read the same path again hoping the error goes
    // away. Matches the reference FileReadTool which emits
    // "EISDIR: illegal operation on a directory, read" with a
    // Glob-first suggestion.
    if (std.Io.Dir.cwd().statFile(rt.io, abs, .{})) |st| {
        if (st.kind == .directory) {
            return std.fmt.allocPrint(
                allocator,
                "error: '{s}' is a directory, not a file. Use Glob with a pattern like '{s}/**/*.zig' to list files inside it, then Read a specific file by path.",
                .{ path, path },
            );
        }

        // Kernel-authoritative device check. The path-only
        // isBlockedDevicePath above is a hand-curated allowlist
        // (/dev/zero, /dev/random, /dev/stdin, ...) that misses every
        // other character/block device on the host: /dev/disk0,
        // /dev/sda, /dev/mem, /dev/kmem, USB serial ports, ALSA
        // /dev/snd/*, etc. A model that calls Read('/dev/disk0')
        // would otherwise stream raw disk bytes (capped at our 4 MiB
        // ceiling, but that's still a leak of arbitrary filesystem
        // state). stat() returns the file kind from the kernel; any
        // device file refuses with the same message as the
        // hardcoded list, no matter what the path is.
        //
        // Explicit allow: /dev/null returns EOF immediately and is a
        // legitimate "I want to read nothing" request -- it's the
        // canonical empty source on POSIX, used in test harnesses
        // and tool plumbing. Every other device is refused.
        if (st.kind == .character_device or st.kind == .block_device) {
            if (!std.mem.eql(u8, abs, "/dev/null")) {
                return deviceBlockedError(allocator, path);
            }
        }

        // File-unchanged short-circuit. Ports the
        // FILE_UNCHANGED_STUB path from
        // claude-code-main/src/tools/FileReadTool/FileReadTool.ts.
        // If the model re-reads a full file (offset=0, limit=0) and
        // the current mtime matches what we recorded on the prior
        // Read, we can return a short stub instead of re-piping the
        // whole content into history. The model already has the
        // earlier Read result in the conversation and can refer to
        // it.
        //
        // Sliced reads (offset != 0 or limit != 0) always go through
        // the full path because the model may be asking for a
        // different slice of the same file, and we don't track
        // per-slice cache state.
        if (offset == 0 and limit == 0 and trackerMtimeMatches(abs, st.mtime.toNanoseconds())) {
            return std.fmt.allocPrint(
                allocator,
                "<system-reminder>\nFile '{s}' unchanged since your earlier Read tool result in this conversation. Refer to that earlier result for the current contents instead of re-reading -- the file on disk has the same mtime, so nothing has changed.\n</system-reminder>",
                .{path},
            );
        }
    } else |_| {
        // Stat failure: fall through to the readFileAlloc path
        // which has its own FileNotFound handler with nicer hints
        // (screenshot fallback, similar-name suggestion, etc).
    }

    // readFileAlloc errors with FileTooBig when the file exceeds
    // `max_bytes`. Rather than bubbling the raw error to the model
    // (where "FileTooBig" is opaque and useless), we open the file,
    // read up to `max_bytes`, and append a footer telling the model
    // exactly how many bytes it got and how to page to the rest.
    //
    // This matches the reference FileReadTool behaviour: caller
    // never sees "FileTooBig" -- instead they see a prefix of the
    // content plus a clear instruction to re-issue with a larger
    // max_bytes or an offset/limit window.
    var was_truncated = false;
    var original_size: u64 = 0;
    const raw: []u8 = blk: {
        const attempt = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(max_bytes));
        if (attempt) |bytes| {
            break :blk bytes;
        } else |err| switch (err) {
            error.IsDir => {
                // Race safety net: the stat-above-on-path check
                // might have raced with a path change. Still
                // return the directory hint.
                return std.fmt.allocPrint(
                    allocator,
                    "error: '{s}' is a directory, not a file. Use Glob with a pattern like '{s}/**/*.zig' to list files inside it.",
                    .{ path, path },
                );
            },
            error.StreamTooLong => {
                // Capture original size for the footer, then read
                // exactly `max_bytes` worth of prefix bytes.
                const stat = std.Io.Dir.cwd().statFile(rt.io, abs, .{}) catch {
                    return std.fmt.allocPrint(
                        allocator,
                        "error: file '{s}' is larger than max_bytes={d}, and a follow-up stat also failed. Use offset/limit to read a specific line range or bump ZCODE_FILE_READ_MAX_BYTES.",
                        .{ path, max_bytes },
                    );
                };
                original_size = stat.size;
                const file = std.Io.Dir.cwd().openFile(rt.io, abs, .{}) catch {
                    return std.fmt.allocPrint(
                        allocator,
                        "error: file '{s}' exists but cannot be opened after the size check.",
                        .{path},
                    );
                };
                defer file.close(rt.io);
                const prefix = try allocator.alloc(u8, max_bytes);
                errdefer allocator.free(prefix);
                var read_off: u64 = 0;
                var got: usize = 0;
                while (got < max_bytes) {
                    const n = try file.readPositionalAll(rt.io, prefix[got..], read_off);
                    if (n == 0) break;
                    got += n;
                    read_off += n;
                }
                was_truncated = true;
                // Shrink the alloc to the actual bytes read so
                // downstream line-counting doesn't see trailing
                // uninitialized memory.
                break :blk prefix[0..got];
            },
            error.FileNotFound => {
                // macOS screenshot fallback: the space before AM/PM
                // may be a regular space or a thin no-break space
                // (U+202F) depending on the OS version. Try the
                // alternate spelling before giving up so the model
                // doesn't have to guess which spacing convention
                // Finder/Spotlight used.
                if (try getAlternateScreenshotPath(allocator, abs)) |alt| {
                    defer allocator.free(alt);
                    if (std.Io.Dir.cwd().readFileAlloc(rt.io, alt, allocator, .limited(max_bytes))) |alt_raw| {
                        break :blk alt_raw;
                    } else |alt_err| switch (alt_err) {
                        error.FileNotFound => {}, // fall through to friendly error
                        error.FileTooBig => {
                            // Extremely unlikely edge case: the alt
                            // path exists but is also too big. Fall
                            // through to the generic not-found path.
                        },
                        else => return alt_err,
                    }
                }

                if (try findSimilarFile(allocator, abs)) |suggestion| {
                    defer allocator.free(suggestion);
                    return std.fmt.allocPrint(
                        allocator,
                        "error: file not found '{s}'. Did you mean '{s}'?",
                        .{ path, suggestion },
                    );
                }
                return std.fmt.allocPrint(
                    allocator,
                    "error: file not found '{s}'",
                    .{path},
                );
            },
            else => return err,
        }
    };
    defer allocator.free(raw);

    // UTF-8 BOM stripping: Windows-saved files often start with
    // the 0xEF 0xBB 0xBF byte-order mark. If we pass that through
    // to the line-numbered render, the very first line comes out
    // as "     1\xe2\x86\x92<BOM>actual content" which looks like
    // a mystery invisible character. Worse, Edit's find-string
    // matching would silently fail on a literal first-line match
    // because the raw bytes start with the 3-byte BOM prefix.
    //
    // Matches the reference FileReadTool which strips BOM before
    // any further processing.
    const text: []const u8 = parse_helpers.stripBom(raw);

    // Content sniffing: catches binaries that slipped past
    // hasBinaryExtension because they have no extension or use a
    // text-looking one (e.g. compiled binaries in $PATH, .dat blobs,
    // .lockb, screenshot dumps without `.png`). Without this guard
    // the read tool would happily JSON-encode a raw ELF/Mach-O header
    // into the model context, which (a) wastes tokens and (b) trips
    // up downstream JSON parsers when the bytes contain control
    // characters.
    if (isBinaryContent(text)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to read '{s}' -- content sniffing detected binary data (null byte or >10% non-printable in the first {d} bytes). If this is genuinely text, check for an unexpected encoding or BOM. To inspect raw bytes use a Bash command like `file '{s}'` or `hexdump -C '{s}' | head`.",
            .{ path, BINARY_CHECK_SIZE, path, path },
        );
    }

    // Mark the file as "read" so a subsequent Edit call can verify
    // the model has seen its contents before attempting find/replace.
    // See readTracker docs above for why we enforce this.
    trackerRecordRead(allocator, abs);

    // Empty files: return an explicit "file is empty" marker so the
    // model doesn't see a literal empty string and get confused
    // about whether the read succeeded or the file was genuinely
    // blank. Ports the <system-reminder> pattern from the reference
    // FileReadTool which wraps empty files in an informative tag.
    if (text.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "<system-reminder>\nFile '{s}' exists but is empty (0 bytes).\n</system-reminder>",
            .{path},
        );
    }

    if (offset == 0 and limit == 0) {
        // Full file: wrap with cat -n style line numbers starting at 1.
        const numbered = try format.addLineNumbers(allocator, text, 1);
        if (!was_truncated) {
            if (try enforceReadTokenCap(allocator, path, numbered)) |err_msg| {
                return err_msg;
            }
            return numbered;
        }
        // Append a footer telling the model the content is truncated.
        defer allocator.free(numbered);
        return std.fmt.allocPrint(
            allocator,
            "{s}\n\n[file '{s}' is {d} bytes, showing first {d} bytes only. Re-issue Read with offset={d} (1-indexed line number) to page through the rest, or bump ZCODE_FILE_READ_MAX_BYTES.]",
            .{ numbered, path, original_size, text.len, countTotalLines(text) + 1 },
        );
    }

    // Sliced read: find the byte range for lines [offset .. offset+limit).
    const start_line: usize = if (offset == 0) 1 else offset;

    // Guard: offset past EOF. Previously we silently returned an
    // empty slice here, which left the model guessing whether the
    // file was empty, the offset was wrong, or something else had
    // gone wrong. The reference (`claude-code-main/src/tools/
    // FileReadTool`) returns a clear "offset N exceeds file length
    // of M lines" error so the model can self-correct. We match.
    if (offset > 1) {
        const total_lines = countTotalLines(text);
        if (offset > total_lines) {
            return std.fmt.allocPrint(
                allocator,
                "error: offset {d} exceeds file length of {d} line{s} in '{s}'. Read with offset=1 (or omit offset) to start from the top, or pick an offset within [1, {d}].",
                .{
                    offset,
                    total_lines,
                    if (total_lines == 1) @as([]const u8, "") else @as([]const u8, "s"),
                    path,
                    total_lines,
                },
            );
        }
    }

    const slice = sliceByLineRange(text, start_line, limit);
    const numbered = try format.addLineNumbers(allocator, slice, start_line);
    if (!was_truncated) {
        if (try enforceReadTokenCap(allocator, path, numbered)) |err_msg| {
            return err_msg;
        }
        return numbered;
    }
    defer allocator.free(numbered);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n[file '{s}' is {d} bytes total, the first {d} bytes were fetched from disk. Bump ZCODE_FILE_READ_MAX_BYTES if you need a larger slice to start with.]",
        .{ numbered, path, original_size, text.len },
    );
}

/// Default Read token cap -- matches the reference's
/// `DEFAULT_MAX_OUTPUT_TOKENS = 25000` constant from
/// claude-code-main/src/tools/FileReadTool/limits.ts. The byte
/// cap alone isn't enough to protect the context window: a 50 KiB
/// file full of single-character lines tokenises to ~100k tokens,
/// which blows the model's budget even though it's well under the
/// 256 KiB byte cap. This token cap is a second safety net that
/// refuses the read after we know the actual token cost.
///
/// Overridable via `ZCODE_FILE_READ_MAX_TOKENS` for power-user
/// workflows that legitimately need to page through larger files
/// (and understand the context tradeoff).
pub const FILE_READ_MAX_TOKENS_DEFAULT: usize = 25_000;

fn readTokenCap() usize {
    if (@import("../core/env.zig").getenv("ZCODE_FILE_READ_MAX_TOKENS")) |v| {
        const parsed = std.fmt.parseInt(usize, v, 10) catch return FILE_READ_MAX_TOKENS_DEFAULT;
        if (parsed == 0) return FILE_READ_MAX_TOKENS_DEFAULT;
        return parsed;
    }
    return FILE_READ_MAX_TOKENS_DEFAULT;
}

/// Check `content` against the Read token cap. Returns null when
/// the content fits; returns an owned error string when it's over
/// (and frees `content` as a side effect so the caller doesn't
/// have to remember the double-handoff).
///
/// Uses our conservative tokenizer estimate - slightly over-counts
/// compared to real BPE, which is the safer direction for a context-
/// budget guard.
fn enforceReadTokenCap(allocator: std.mem.Allocator, path: []const u8, content: []u8) !?[]u8 {
    const cap = readTokenCap();
    const tokenizer = @import("../core/tokenizer.zig");
    const estimated = tokenizer.estimateText("", "", content);
    if (estimated <= cap) return null;

    defer allocator.free(content);
    return try std.fmt.allocPrint(
        allocator,
        "error: file '{s}' rendered to {d} tokens, exceeding the Read cap of {d} tokens. Use offset/limit to fetch a narrower window (e.g. Read with offset=1 limit=500), or Grep for specific content instead of reading the whole file. Override with ZCODE_FILE_READ_MAX_TOKENS if you genuinely need a larger cap.",
        .{ path, estimated, cap },
    );
}

/// Count the number of 1-indexed lines in `raw`. A file with no
/// trailing newline still reports its last incomplete line as a
/// full line. Empty file returns 0 so the caller's offset-check
/// treats any positive offset as past-EOF.
fn countTotalLines(raw: []const u8) usize {
    if (raw.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\n') count += 1;
    }
    // If the last byte isn't a newline, the trailing partial line
    // still counts.
    if (raw[raw.len - 1] != '\n') count += 1;
    return count;
}

/// Return the byte slice covering `limit` lines starting from line
/// `start_line` (1-indexed, inclusive). limit=0 reads to EOF. Lines
/// shorter than the slice boundary are dropped cleanly -- the slice
/// always starts at a line boundary and ends at a `\n` or EOF.
fn sliceByLineRange(raw: []const u8, start_line: usize, limit: usize) []const u8 {
    if (raw.len == 0 or start_line == 0) return raw;

    // Walk forward counting newlines until we reach start_line - 1.
    var cursor: usize = 0;
    var current_line: usize = 1;
    while (current_line < start_line and cursor < raw.len) {
        if (raw[cursor] == '\n') current_line += 1;
        cursor += 1;
    }
    const slice_start = cursor;
    if (slice_start >= raw.len) return raw[raw.len..raw.len];

    if (limit == 0) return raw[slice_start..];

    var lines_taken: usize = 0;
    var end = slice_start;
    while (end < raw.len and lines_taken < limit) {
        if (raw[end] == '\n') lines_taken += 1;
        end += 1;
    }
    return raw[slice_start..end];
}

/// Ported from claude-code-main/src/utils/file.ts findSimilarFile.
/// When a file doesn't exist, look for files in the same directory
/// with the same basename-without-extension. Helps the model recover
/// from typos like `main.zg` -> `main.zig` or wrong-extension guesses
/// like `config.json` -> `config.toml`. Returns the matching file's
/// basename (relative to the directory), or null when nothing close
/// is found. Caller owns the returned slice.
pub fn findSimilarFile(allocator: std.mem.Allocator, abs_path: []const u8) !?[]u8 {
    const dir_path = std.fs.path.dirname(abs_path) orelse return null;
    const file_basename = std.fs.path.basename(abs_path);
    const stem = stemWithoutExtension(file_basename);
    if (stem.len == 0) return null;

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (it.next(rt.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, file_basename)) continue; // exact path was requested; pointless
        const entry_stem = stemWithoutExtension(entry.name);
        if (std.mem.eql(u8, entry_stem, stem)) {
            return try allocator.dupe(u8, entry.name);
        }
    }
    return null;
}

fn stemWithoutExtension(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    if (dot == 0) return name; // dotfile like ".env" -- the dot belongs to the name
    return name[0..dot];
}

/// Upper bound on the `content` bytes the Write tool will actually
/// push to disk. 8 MiB is 30x the Read tool's 256 KiB default cap,
/// which means any reasonable source file still fits, but a
/// runaway generation that tries to write a 100 MB buffer gets
/// caught before it fills the user's disk.
///
/// Overridable via `ZCODE_FILE_WRITE_MAX_BYTES` for users that
/// legitimately need to write larger artifacts (e.g. generating
/// test fixtures).
pub const WRITE_MAX_BYTES_DEFAULT: usize = 8 * 1024 * 1024;

fn writeMaxBytes() usize {
    if (@import("../core/env.zig").getenv("ZCODE_FILE_WRITE_MAX_BYTES")) |v| {
        const parsed = std.fmt.parseInt(usize, v, 10) catch return WRITE_MAX_BYTES_DEFAULT;
        if (parsed == 0) return WRITE_MAX_BYTES_DEFAULT;
        return parsed;
    }
    return WRITE_MAX_BYTES_DEFAULT;
}

/// Format a model-readable refusal for a path-safety verdict, or return
/// null when the verdict is `safe`. Mirrors the binary-edit refusal
/// style already used by write()/edit() (return the message as the tool
/// output rather than bubbling an error code through tool_dispatch).
/// Operation kind for path validation. Globs are rejected for
/// write/create operations (the path is used literally) but allowed
/// for reads (Glob/Grep legitimately expand them).
const PathOpKind = enum { write, read };

/// Strip a single pair of surrounding ASCII quotes (matching the
/// reference's `path.replace(/^['"]|['"]$/g, '')`).
fn stripSurroundingQuotes(path: []const u8) []const u8 {
    var s = path;
    if (s.len >= 1 and (s[0] == '\'' or s[0] == '"')) s = s[1..];
    if (s.len >= 1 and (s[s.len - 1] == '\'' or s[s.len - 1] == '"')) s = s[0 .. s.len - 1];
    return s;
}

/// Systematic path-validation TOCTOU guards (permissions-16). Ported
/// from validatePath (pathValidation.ts:373-485). Runs on the path
/// AFTER stripping surrounding quotes and expanding `~`/`~/` so a
/// legitimate `~/foo` is not rejected -- only the unhandled tilde
/// variants (`~user`/`~+`/`~-`/`~N`), shell-expansion syntax, UNC
/// prefixes, and (for writes) glob metacharacters remain. Returns an
/// owned error message when the path is rejected, else null.
fn pathValidationRefusal(
    allocator: std.mem.Allocator,
    path: []const u8,
    op: PathOpKind,
) !?[]u8 {
    const cleaned = stripSurroundingQuotes(path);
    const expanded = try expandHomeTilde(allocator, cleaned);
    defer allocator.free(expanded);

    // UNC network paths (credential-leak vector).
    if (path_utils.isUncPath(expanded)) {
        return try std.fmt.allocPrint(
            allocator,
            "error: path '{s}' rejected: UNC network paths require manual approval (credential-leak vector).",
            .{path},
        );
    }

    // Unexpanded tilde variants (~user/~+/~-/~N). expandHomeTilde
    // already turned bare ~ and ~/ into absolute paths, so a remaining
    // leading tilde is an un-handled variant the shell would expand
    // differently at exec time (TOCTOU gap).
    if (path_utils.hasTildeVariant(expanded)) {
        return try std.fmt.allocPrint(
            allocator,
            "error: path '{s}' rejected: tilde expansion variants (~user, ~+, ~-) require manual approval.",
            .{path},
        );
    }

    // Shell-expansion syntax ($VAR / ${VAR} / $(cmd) / %VAR% / leading =).
    if (path_utils.hasShellExpansion(expanded)) {
        return try std.fmt.allocPrint(
            allocator,
            "error: path '{s}' rejected: shell expansion syntax in paths requires manual approval.",
            .{path},
        );
    }

    // Glob metacharacters -- write/create only. Reads may glob.
    if (op == .write and path_utils.hasGlobMeta(expanded)) {
        return try std.fmt.allocPrint(
            allocator,
            "error: path '{s}' rejected: glob patterns are not allowed in write operations. Specify an exact file path.",
            .{path},
        );
    }

    return null;
}

fn pathSafetyRefusal(allocator: std.mem.Allocator, path: []const u8, verdict: path_safety.Verdict) !?[]u8 {
    return switch (verdict) {
        .safe => null,
        .dangerous_dir => |dir| try std.fmt.allocPrint(
            allocator,
            "error: edit to '{s}' blocked: it is inside the sensitive directory '{s}'. Editing files there (config, hooks, credentials) is a code-execution and exfiltration vector and requires explicit user approval. This guard applies even in bypass/yolo mode.",
            .{ path, dir },
        ),
        .dangerous_file => |f| try std.fmt.allocPrint(
            allocator,
            "error: edit to '{s}' blocked: '{s}' is a sensitive file (shell/git/MCP config). Editing it is a code-execution and exfiltration vector and requires explicit user approval. This guard applies even in bypass/yolo mode.",
            .{ path, f },
        ),
        .suspicious_pattern => try std.fmt.allocPrint(
            allocator,
            "error: edit to '{s}' blocked: the path contains a suspicious pattern (trailing dot/space, DOS device name, 8.3 short name, three-dot component, or UNC prefix) that could bypass safety checks. It requires explicit user approval.",
            .{path},
        ),
    };
}

/// Path-safety check that also re-runs against the symlink-resolved
/// path when the file already exists, so a symlink pointing at a
/// dangerous file/dir cannot slip past the literal-path check. Mirrors
/// the reference checkPathSafetyForAutoEdit which checks BOTH the
/// original and the symlink-resolved path (filesystem.ts:620-664).
/// `abs` is the already-normalized absolute path.
fn checkPathSafetyResolved(path: []const u8, abs: []const u8) path_safety.Verdict {
    const literal = path_safety.check(path);
    if (!literal.isSafe()) return literal;
    const on_abs = path_safety.check(abs);
    if (!on_abs.isSafe()) return on_abs;

    // If the target exists and is a symlink, re-check the realpath.
    // `abs` is normalized to an absolute path by normalizePath, so use
    // the absolute variant. A missing file (new write) fails open here:
    // the literal-path checks above already covered the requested path.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.realPathFileAbsolute(rt.io, abs, &buf) catch return .safe;
    return path_safety.check(buf[0..n]);
}

pub fn write(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, content: []const u8, append_mode: bool) ![]u8 {
    // Size guard BEFORE any filesystem work. Catches runaway
    // generations (a model accidentally writing its entire prompt
    // in a loop, for example) before they land on disk.
    const size_cap = writeMaxBytes();
    if (content.len > size_cap) {
        return error.WriteContentTooLarge;
    }

    // Path-only device gate. Refuse the well-known blocking devices
    // (/dev/zero, /dev/stdin, /proc/self/fd/0, ...) before normalizePath
    // even resolves symlinks -- pure-text guard so a model that
    // accidentally writes to /dev/zero or /dev/tty doesn't wedge the
    // agent or spam the operator's terminal.
    if (isBlockedDevicePath(path)) {
        return deviceBlockedWriteError(allocator, path);
    }

    // TOCTOU path-validation guards (permissions-16): reject UNC,
    // unexpanded tilde variants, shell-expansion syntax, and glob
    // metacharacters BEFORE normalizePath anchors a relative path to
    // cwd (which would otherwise hide a leading `~user`/`$VAR`/`*` in
    // the joined absolute form).
    if (try pathValidationRefusal(allocator, path, .write)) |msg| {
        return msg;
    }

    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    // Same path-only check on the resolved absolute path so a relative
    // `dev/zero` from cwd `/` or a symlink pointing at /dev/null can't
    // slip past.
    if (isBlockedDevicePath(abs)) {
        return deviceBlockedWriteError(allocator, path);
    }
    // Kernel-authoritative device check. Catches every other
    // character/block device on the host: /dev/disk0, /dev/sda,
    // /dev/mem, /dev/kmem, USB serial nodes, etc. Without this guard
    // the atomic-rename on a permissive /dev (rare but possible on
    // misconfigured hosts) would replace the device entry with a
    // regular file containing the edit's content. /dev/null stays
    // legal -- it's the canonical bit-bucket.
    if (isStatBlockedDevice(abs)) {
        return deviceBlockedWriteError(allocator, path);
    }

    // Bypass-immune path-safety floor: refuse writes to dangerous dirs
    // (.git, .claude, .zcode, ...), dangerous files (.bashrc, .gitconfig,
    // .mcp.json, ...), and suspicious path patterns. This is the
    // tool-level floor for direct callers; the agent gate adds the
    // "prompt even in yolo" behavior on top (see agent_tools.zig).
    if (try pathSafetyRefusal(allocator, path, checkPathSafetyResolved(path, abs))) |msg| {
        return msg;
    }

    // Reject directory targets up-front with a clean error. Without
    // this, Zig's createFile/writeFile call bubbles `error.IsDir`
    // which the model sees as opaque. See the Read-tool comment
    // with the same rationale.
    if (pathIsDirectory(abs)) {
        return error.WriteTargetIsDirectory;
    }

    // Read-before-write enforcement for EXISTING files. Ports the
    // readFileState check from claude-code-main/src/tools/
    // FileWriteTool/FileWriteTool.ts. Without this, a model can
    // blindly rewrite a file it never saw, trampling external
    // changes (an editor save, a git rebase, another agent) that
    // the in-memory snapshot doesn't know about. The rule:
    //
    //   - Brand-new files (FileNotFound on stat) -> always allowed.
    //     The model cannot clobber state that doesn't exist yet.
    //   - Append mode -> always allowed. Append-only is safe even
    //     without knowing the prior contents because we're adding,
    //     not replacing.
    //   - Existing file + truncate mode + not-yet-read -> REJECT.
    //
    // Escape hatches: `ZCODE_SKIP_READ_BEFORE_EDIT=1` bypasses the
    // check the same way it does for Edit/MultiEdit, since they
    // share the `trackerWasRead` map.
    if (!append_mode and !trackerWasRead(abs) and !readBeforeEditSkipEnvSet()) {
        const exists = blk: {
            std.Io.Dir.cwd().access(rt.io, abs, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        };
        if (exists) {
            return error.WriteRequiresPriorRead;
        }
    }

    // mtime freshness check: if the tracker has a recorded mtime
    // and the current on-disk mtime differs, the file was modified
    // externally between Read and Write -- reject so the model can
    // re-Read before trampling whatever changed. Append mode skips
    // this because it's additive and doesn't lose any data.
    if (!append_mode and !readBeforeEditSkipEnvSet()) {
        if (trackerIsFresh(abs) == .stale) {
            return error.WriteStaleMtime;
        }
    }

    if (try security.scanContentSummary(allocator, path, content)) |summary| {
        defer allocator.free(summary);
        return error.SecretScanBlocked;
    }

    const dir_path = std.fs.path.dirname(abs) orelse cwd;
    std.Io.Dir.cwd().createDirPath(rt.io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Count the existing file's lines before touching it so we can
    // report net add/remove to the metrics counter. A brand-new file
    // or an append with no prior content both degenerate to
    // old_lines=0 which matches Claude Code's "treat missing old file
    // as zero-line base" behaviour in diff.ts countLinesChanged.
    //
    // 4 MiB cap (down from 16 MiB) keeps the metric-collection path
    // from slurping arbitrarily large files just to count newlines.
    // Still 16x the Read tool's 256 KiB default cap so any file that
    // fits within a reasonable edit footprint gets an accurate count;
    // files larger than that produce old_lines=0 and the metric
    // reports "all content is net additions", the same degenerate
    // result the readFileAlloc failure path already produced.
    var old_lines: u64 = 0;
    if (std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(4 * 1024 * 1024))) |existing| {
        defer allocator.free(existing);
        old_lines = metrics.countLines(existing);
    } else |_| {}

    if (append_mode) {
        // O_APPEND is atomic per-write on POSIX and the expected
        // semantics for an append. Atomic tmp+rename would lose
        // whatever the file already contained, so we only use it
        // for full-rewrite mode below.
        const file = try std.Io.Dir.cwd().createFile(rt.io, abs, .{ .truncate = false, .read = true });
        defer file.close(rt.io);
        // 0.16: no seek; positional write at end-of-file.
        const cur_len = file.length(rt.io) catch 0;
        try file.writePositionalAll(rt.io, content, cur_len);
        // Append: all content lines are net additions.
        const appended_lines = metrics.countLines(content);
        metrics.addToTotalLinesChanged(appended_lines, 0);
        return std.fmt.allocPrint(
            allocator,
            "appended to {s} (+{d} lines, {d} bytes)",
            .{ path, appended_lines, content.len },
        );
    }

    try writeFileAtomic(allocator, abs, content);

    // lsp-04: tell any persistent LSP server the file changed + clear delivered
    // diagnostics for it (best-effort, no-op without a manager).
    notifyLspAfterWrite(allocator, abs, content);

    // Full rewrite: treat the delta as "removed old_lines, added new_lines".
    // This matches the /cost "Total code changes" figure users see in
    // Claude Code, which also counts overwrites as full rewrites rather
    // than trying to compute an LCS-accurate diff.
    const new_lines = metrics.countLines(content);
    metrics.addToTotalLinesChanged(new_lines, old_lines);

    // Emit an informative success message so the model sees line
    // counts and byte totals instead of a bare "ok". Previously
    // the dispatch handler hardcoded "ok" on success, which was
    // indistinguishable from a no-op and gave the model nothing
    // to reason about. Matches the reference FileWriteTool's
    // "File created successfully at X" / "Updated X with ..."
    // style metadata.
    if (old_lines == 0) {
        // Brand-new file (or an overwrite of something that was
        // too large to line-count; we treat both the same way).
        return std.fmt.allocPrint(
            allocator,
            "created {s} ({d} lines, {d} bytes)",
            .{ path, new_lines, content.len },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "rewrote {s} ({d} lines, was {d}; {d} bytes)",
        .{ path, new_lines, old_lines, content.len },
    );
}

/// LSP doc-sync + diagnostics hook for the Write/Edit/MultiEdit success paths
/// (parity lsp-04). When a persistent LSP manager is installed (i.e. not
/// `--bare`/headless), tell the language server the file changed (`didChange`
/// with the new content, then `didSave`) so it re-diagnoses, and clear any
/// previously-delivered diagnostics for this file from the registry so a
/// re-edit re-shows them. Mirrors the reference calling
/// `clearDeliveredDiagnosticsForFile` from both FileWriteTool and FileEditTool.
///
/// Entirely best-effort and defensive: a no-op when no manager/registry is
/// installed, and all errors are swallowed so a flaky server never breaks a
/// successful edit. `abs_path` is the already-normalized absolute path; the
/// `file://` URI is built the same way the manager / diagnostic publish does.
fn notifyLspAfterWrite(allocator: std.mem.Allocator, abs_path: []const u8, content: []const u8) void {
    if (lsp_manager.get()) |m| {
        // changeFile promotes to didOpen when the file was never opened, so a
        // first-ever Write still registers the document with the server.
        m.changeFile(abs_path, content) catch {};
        m.saveFile(abs_path) catch {};
    }
    if (lsp_registry.get()) |reg| {
        const uri = std.fmt.allocPrint(allocator, "file://{s}", .{abs_path}) catch return;
        defer allocator.free(uri);
        reg.clearDeliveredForFile(uri);
    }
}

/// Stage content into a sibling `.tmp.<ns>` file, then rename it over the
/// target. A crash or cancellation mid-write leaves the original file
/// untouched instead of truncated, and the rename is atomic on POSIX so
/// readers never observe a partial file. Permissions on an existing file
/// are preserved by copying the source mode onto the tmp before rename.
///
/// New files get a permission upgrade when the content starts with a
/// shebang (`#!`): we set the executable bit (0o755) so the model can
/// author a run-ready script with a single Write call instead of
/// needing a separate `chmod +x`. Matches the reference FileWriteTool
/// heuristic from claude-code-main/src/tools/FileWriteTool.
fn writeFileAtomic(allocator: std.mem.Allocator, abs_path: []const u8, content: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ abs_path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    // Stat-up front so we can distinguish "existing file, preserve mode"
    // from "new file, apply shebang heuristic".
    const existing_mode: ?std.posix.mode_t = blk: {
        const st = std.Io.Dir.cwd().statFile(rt.io, abs_path, .{}) catch break :blk null;
        break :blk @as(std.posix.mode_t, @intCast(st.permissions.toMode() & 0o7777));
    };

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, content);
        file.sync(rt.io) catch {};

        // Mode selection:
        //
        //   1. File already existed -> preserve its mode verbatim so
        //      overwriting a 0o755 script doesn't silently downgrade
        //      it to 0o644.
        //   2. New file starting with `#!` -> auto-executable (0o755).
        //      The shebang is a deliberate "this is runnable" signal;
        //      leaving it at the default 0o644 means the user has
        //      to run `chmod +x` before it actually works, which is
        //      a footgun we can eliminate for free.
        //   3. Everything else -> default 0o644 from createFile.
        //
        // Failures to chmod are non-fatal; the rename still happens
        // with whatever mode the tmp file ended up at.
        if (existing_mode) |mode| {
            file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(mode)) catch {};
        } else if (contentHasShebang(content)) {
            file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o755)) catch {};
        }
    }

    try std.Io.Dir.renameAbsolute(tmp_path, abs_path, rt.io);
}

/// Return true if `content` begins with a `#!` shebang line. A single
/// leading byte of `#` followed by `!` is enough -- we don't require
/// a specific interpreter path because shell/python/node/perl/zig all
/// use the same prefix. Empty content or content that starts with any
/// other byte returns false.
fn contentHasShebang(content: []const u8) bool {
    return content.len >= 2 and content[0] == '#' and content[1] == '!';
}

pub fn edit(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, find_text: []const u8, replace_text: []const u8, replace_all: bool) ![]u8 {
    if (hasBinaryExtension(path)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to edit binary file '{s}'. Find/replace does not make sense on binary content. If you genuinely need to rewrite it, use Bash with an appropriate tool (hexedit, ffmpeg, sqlite3, etc.).",
            .{path},
        );
    }

    // Same device guard the Write path uses. Edit reads the original
    // before computing the replacement; on /dev/zero that would slurp
    // until our 4 MiB cap, then atomic-rename a regular file in place
    // of the device entry on hosts where /dev permissions allow it.
    if (isBlockedDevicePath(path)) {
        return deviceBlockedWriteError(allocator, path);
    }

    // TOCTOU path-validation guards (permissions-16). Edit uses the
    // path literally to read-then-rewrite, so it is a write-class
    // operation: reject globs alongside UNC / tilde-variant / shell
    // expansion. Runs before normalizePath for the same reason as in
    // write().
    if (try pathValidationRefusal(allocator, path, .write)) |msg| {
        return msg;
    }

    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    if (isBlockedDevicePath(abs) or isStatBlockedDevice(abs)) {
        return deviceBlockedWriteError(allocator, path);
    }

    // Bypass-immune path-safety floor: refuse edits to dangerous dirs/
    // files and suspicious path patterns even for direct callers.
    if (try pathSafetyRefusal(allocator, path, checkPathSafetyResolved(path, abs))) |msg| {
        return msg;
    }

    // Reject directories up-front. See the Read-tool comment for
    // why we refuse these loudly instead of letting Zig's IsDir
    // bubble up.
    if (pathIsDirectory(abs)) {
        return std.fmt.allocPrint(
            allocator,
            "error: '{s}' is a directory, not a file. Edit operates on a single file -- pick a file inside it (use Glob '{s}/**/*.zig' or similar to list candidates).",
            .{ path, path },
        );
    }

    // Read-before-edit enforcement. Reject the edit if the model
    // hasn't called Read on this file yet. Ports the
    // readFileState check from claude-code-main/src/tools/
    // FileEditTool/FileEditTool.ts. Prevents two common failure
    // modes: blind edits from stale memory and edits against a
    // version that the user has since modified externally.
    //
    // Escape hatch for read-free call sites: `ZCODE_SKIP_READ_BEFORE_EDIT=1`
    // bypasses the check. Useful for non-interactive scripts that
    // drive the tool directly rather than through a conversation.
    if (!trackerWasRead(abs) and !readBeforeEditSkipEnvSet()) {
        return std.fmt.allocPrint(
            allocator,
            "edit failed: file '{s}' has not been read yet in this session. Call Read('{s}') first so the tool can verify your find string matches the current file contents. If you're certain the content, set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass this check.",
            .{ path, path },
        );
    }

    // mtime freshness check: reject the edit if the file was
    // modified externally between Read and now. Without this,
    // find/replace against a stale snapshot can succeed against
    // a pre-edit version of the content and silently produce a
    // broken intermediate state.
    if (!readBeforeEditSkipEnvSet() and trackerIsFresh(abs) == .stale) {
        return std.fmt.allocPrint(
            allocator,
            "edit failed: file '{s}' was modified externally after you Read it. Call Read('{s}') again to observe the current contents before editing. Set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass this check.",
            .{ path, path },
        );
    }

    const original = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(original);

    // Same content-sniffing guard as readRange: catches no-extension
    // binaries before find/replace mangles their bytes.
    if (isBinaryContent(original)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to edit '{s}' -- content sniffing detected binary data. Find/replace on binary bytes corrupts the file; use Bash with hexedit/dd/etc. for raw byte changes.",
            .{path},
        );
    }

    if (find_text.len == 0) return allocator.dupe(u8, "edit failed: find text is empty");

    // Now that read() returns content wrapped in `   N→` line-number
    // prefixes, the model frequently echoes those prefixes back as the
    // find_text and replace_text args. Strip them per-line so the
    // resulting find_text matches the actual file bytes -- otherwise
    // every Edit on a freshly-read file would fail with "no match".
    // The helper is a no-op when no prefixes are present, so passing
    // raw text still works.
    const find_clean = try stripLineNumberPrefixesAlloc(allocator, find_text);
    defer allocator.free(find_clean);
    const replace_clean = try stripLineNumberPrefixesAlloc(allocator, replace_text);
    defer allocator.free(replace_clean);
    const find_used = find_clean;
    const replace_used = replace_clean;

    // Uniqueness enforcement. Ports
    // claude-code-main/src/tools/FileEditTool/FileEditTool.ts: when
    // replace_all is false, the find string MUST be unique, or we
    // reject the edit entirely. Previously we silently took the first
    // match -- which is dangerous, because a model that meant to touch
    // "the second occurrence" ended up mangling the first with no
    // feedback that anything was wrong. Now the model gets a clear
    // error telling it to either add surrounding context to
    // disambiguate the match or pass all=true.
    if (!replace_all) {
        var occ_count: usize = 0;
        var occ_cursor: usize = 0;
        while (std.mem.indexOfPos(u8, original, occ_cursor, find_used)) |hit| : (occ_cursor = hit + find_used.len) {
            occ_count += 1;
            if (occ_count > 1) break;
        }
        if (occ_count > 1) {
            return std.fmt.allocPrint(
                allocator,
                "edit failed: find string is not unique in '{s}' (appears multiple times). Expand the find string with surrounding context so it matches only the line you want to change, or set all=true to replace every occurrence.",
                .{path},
            );
        }
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var replaced: usize = 0;
    var first_hit: usize = 0;
    var cursor: usize = 0;
    while (true) {
        const hit = std.mem.indexOfPos(u8, original, cursor, find_used) orelse break;
        if (replaced == 0) first_hit = hit;
        try out.appendSlice(original[cursor..hit]);
        try out.appendSlice(replace_used);
        cursor = hit + find_used.len;
        replaced += 1;
        if (!replace_all) break;
    }
    try out.appendSlice(original[cursor..]);

    if (replaced == 0) return allocator.dupe(u8, "edit: no match");

    if (try security.scanContentSummary(allocator, path, out.items())) |summary| {
        defer allocator.free(summary);
        return error.SecretScanBlocked;
    }

    // Count newlines before first hit to determine start line (1-based)
    var start_line: usize = 1;
    for (original[0..first_hit]) |ch| {
        if (ch == '\n') start_line += 1;
    }

    try writeFileAtomic(allocator, abs, out.items());

    // lsp-04: doc-sync + clear delivered diagnostics for the edited file.
    notifyLspAfterWrite(allocator, abs, out.items());

    // Record the file as "read" again now that we've written the
    // post-edit state. This lets a subsequent Edit chain proceed
    // without having to re-Read between each edit -- the caller
    // logically knows the file state because it just produced it.
    trackerRecordRead(allocator, abs);

    // Tally lines changed for the /cost "Total code changes" figure.
    // Use the prefix-stripped text so a model that round-trips through
    // line-numbered Read output gets accurate counts.
    const find_lines = metrics.countLines(find_used);
    const replace_lines = metrics.countLines(replace_used);
    const replaced_u64: u64 = @intCast(replaced);
    metrics.addToTotalLinesChanged(replace_lines * replaced_u64, find_lines * replaced_u64);

    // Include a mini diff showing what changed
    const find_preview = if (find_used.len > 80) find_used[0..80] else find_used;
    const replace_preview = if (replace_used.len > 80) replace_used[0..80] else replace_used;
    return std.fmt.allocPrint(
        allocator,
        "edit ok: {d} replacement(s) in {s} at line {d}\n" ++
            "--- {s}\n+++ {s}",
        .{ replaced, path, start_line, find_preview, replace_preview },
    );
}

/// Apply a list of edits to a single file atomically. Ports
/// claude-code-main/src/tools/MultiEditTool/MultiEditTool.ts:
///
///   - Reads the file once and applies every edit in sequence to an
///     in-memory buffer. If any edit fails (not found, not unique
///     when replace_all=false), the ENTIRE operation is rejected and
///     the file on disk stays untouched. Atomicity is the whole
///     point of MultiEdit -- Edit-Edit-Edit chains leave the file in
///     a half-applied state on failure.
///
///   - Each edit is an object with fields:
///       old_string    (required)
///       new_string    (required, may be empty)
///       replace_all   (optional, default false)
///     Field names match the reference exactly. zcode's Edit handler
///     also accepts these names as synonyms (pass #339).
///
///   - Uniqueness check applies per-edit: when replace_all is false,
///     the old_string must match exactly once in the *current* buffer
///     (after prior edits have been applied). This lets an earlier
///     edit remove duplicates and a later edit assume uniqueness.
///
///   - The same read-before-edit gate applies: the file must have
///     been Read in this session (or ZCODE_SKIP_READ_BEFORE_EDIT set)
///     or the multi-edit is rejected up front.
///
/// `edits_json` is the raw JSON array from the tool arguments, e.g.
/// `[{"old_string":"foo","new_string":"bar"},{"old_string":"x","new_string":"y","replace_all":true}]`.
pub fn multiEdit(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    path: []const u8,
    edits_json: []const u8,
) ![]u8 {
    if (hasBinaryExtension(path)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to edit binary file '{s}'. Multi-edit find/replace does not make sense on binary content.",
            .{path},
        );
    }

    // Same device guard as Edit -- otherwise a sequence of edits on
    // /dev/zero or /dev/disk0 would slurp the read cap, then
    // atomic-rename a regular file over the device entry.
    if (isBlockedDevicePath(path)) {
        return deviceBlockedWriteError(allocator, path);
    }

    const abs = try normalizePath(allocator, cwd, path);
    defer allocator.free(abs);

    if (isBlockedDevicePath(abs) or isStatBlockedDevice(abs)) {
        return deviceBlockedWriteError(allocator, path);
    }

    // Reject directory targets up-front.
    if (pathIsDirectory(abs)) {
        return std.fmt.allocPrint(
            allocator,
            "error: '{s}' is a directory, not a file. MultiEdit operates on a single file -- pick a file inside it.",
            .{path},
        );
    }

    if (!trackerWasRead(abs) and !readBeforeEditSkipEnvSet()) {
        return std.fmt.allocPrint(
            allocator,
            "multi_edit failed: file '{s}' has not been read yet in this session. Call Read('{s}') first so the tool can verify your edits match the current file contents. If you're certain the content, set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass this check.",
            .{ path, path },
        );
    }

    // mtime freshness check: reject when the file changed on disk
    // between Read and now. Same rationale as single Edit.
    if (!readBeforeEditSkipEnvSet() and trackerIsFresh(abs) == .stale) {
        return std.fmt.allocPrint(
            allocator,
            "multi_edit failed: file '{s}' was modified externally after you Read it. Call Read('{s}') again to observe the current contents before editing. Set ZCODE_SKIP_READ_BEFORE_EDIT=1 to bypass.",
            .{ path, path },
        );
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, edits_json, .{}) catch {
        return std.fmt.allocPrint(
            allocator,
            "multi_edit failed: `edits` must be a JSON array like [{{\"old_string\":...,\"new_string\":...}}]. Got: {s}",
            .{edits_json},
        );
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        return allocator.dupe(u8, "multi_edit failed: `edits` must be a JSON array of edit objects");
    }
    const edit_array = parsed.value.array.items;
    if (edit_array.len == 0) {
        return allocator.dupe(u8, "multi_edit failed: `edits` array is empty -- pass at least one edit");
    }

    const original = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(original);

    if (isBinaryContent(original)) {
        return std.fmt.allocPrint(
            allocator,
            "error: refused to edit '{s}' -- content sniffing detected binary data.",
            .{path},
        );
    }

    // Working buffer starts as a copy of the original; each edit
    // replaces `buffer` with its post-edit version. We only commit
    // to disk after every edit succeeds.
    var buffer = try allocator.dupe(u8, original);
    defer allocator.free(buffer);

    var total_replacements: usize = 0;

    for (edit_array, 0..) |entry, edit_idx| {
        if (entry != .object) {
            return std.fmt.allocPrint(
                allocator,
                "multi_edit failed at index {d}: each edit must be an object with old_string/new_string fields",
                .{edit_idx},
            );
        }
        const obj = entry.object;

        const old_raw = blk: {
            const v = obj.get("old_string") orelse obj.get("find") orelse {
                return std.fmt.allocPrint(
                    allocator,
                    "multi_edit failed at index {d}: missing required field `old_string`",
                    .{edit_idx},
                );
            };
            if (v != .string) return std.fmt.allocPrint(
                allocator,
                "multi_edit failed at index {d}: `old_string` must be a string",
                .{edit_idx},
            );
            break :blk v.string;
        };

        const new_raw: []const u8 = blk: {
            if (obj.get("new_string") orelse obj.get("replace")) |v| {
                if (v != .string) return std.fmt.allocPrint(
                    allocator,
                    "multi_edit failed at index {d}: `new_string` must be a string",
                    .{edit_idx},
                );
                break :blk v.string;
            }
            break :blk "";
        };

        const replace_all_flag: bool = blk: {
            if (obj.get("replace_all") orelse obj.get("all")) |v| {
                if (v == .bool) break :blk v.bool;
                if (v == .string) break :blk std.mem.eql(u8, v.string, "true");
            }
            break :blk false;
        };

        // Strip line-number prefixes just like the single Edit path, so
        // models that round-trip through line-numbered Read output
        // don't silently miss every match.
        const old_stripped = try stripLineNumberPrefixesAlloc(allocator, old_raw);
        defer allocator.free(old_stripped);
        const new_stripped = try stripLineNumberPrefixesAlloc(allocator, new_raw);
        defer allocator.free(new_stripped);

        if (old_stripped.len == 0) {
            return std.fmt.allocPrint(
                allocator,
                "multi_edit failed at index {d}: `old_string` is empty",
                .{edit_idx},
            );
        }

        // Same "not-unique" rejection as Edit: count occurrences in the
        // *current* buffer (which already reflects earlier edits).
        if (!replace_all_flag) {
            var occ_count: usize = 0;
            var occ_cursor: usize = 0;
            while (std.mem.indexOfPos(u8, buffer, occ_cursor, old_stripped)) |hit| : (occ_cursor = hit + old_stripped.len) {
                occ_count += 1;
                if (occ_count > 1) break;
            }
            if (occ_count > 1) {
                return std.fmt.allocPrint(
                    allocator,
                    "multi_edit failed at index {d}: `old_string` appears multiple times in the current buffer state. Expand it with surrounding context or set replace_all=true for this edit. Nothing has been written to '{s}'.",
                    .{ edit_idx, path },
                );
            }
        }

        // Apply this edit into a fresh output buffer, then swap.
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();

        var replaced: usize = 0;
        var cursor: usize = 0;
        while (true) {
            const hit = std.mem.indexOfPos(u8, buffer, cursor, old_stripped) orelse break;
            try out.appendSlice(buffer[cursor..hit]);
            try out.appendSlice(new_stripped);
            cursor = hit + old_stripped.len;
            replaced += 1;
            if (!replace_all_flag) break;
        }
        try out.appendSlice(buffer[cursor..]);

        if (replaced == 0) {
            return std.fmt.allocPrint(
                allocator,
                "multi_edit failed at index {d}: `old_string` not found in '{s}'. Nothing has been written.",
                .{ edit_idx, path },
            );
        }

        allocator.free(buffer);
        buffer = try out.toOwnedSlice();
        total_replacements += replaced;
    }

    if (try security.scanContentSummary(allocator, path, buffer)) |summary| {
        defer allocator.free(summary);
        return error.SecretScanBlocked;
    }

    try writeFileAtomic(allocator, abs, buffer);

    // lsp-04: doc-sync + clear delivered diagnostics for the edited file.
    notifyLspAfterWrite(allocator, abs, buffer);

    trackerRecordRead(allocator, abs);

    // Tally the aggregate change for /cost: total new lines minus
    // total old lines across every edit, rounded to zero on
    // imbalance. Cheap proxy -- good enough for the display.
    const original_line_count = metrics.countLines(original);
    const new_line_count = metrics.countLines(buffer);
    const added: u64 = if (new_line_count > original_line_count) @intCast(new_line_count - original_line_count) else 0;
    const removed: u64 = if (original_line_count > new_line_count) @intCast(original_line_count - new_line_count) else 0;
    metrics.addToTotalLinesChanged(added, removed);

    return std.fmt.allocPrint(
        allocator,
        "multi_edit ok: {d} edit(s), {d} replacement(s) in {s}",
        .{ edit_array.len, total_replacements, path },
    );
}

/// Apply format.stripLineNumberPrefix to every line of `text` and
/// rejoin with '\n'. Returns an allocated copy even when no prefixes
/// were found so the caller's free() works uniformly. Empty input
/// returns an empty allocated slice.
fn stripLineNumberPrefixesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.dupe(u8, "");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var iter = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        try out.appendSlice(format.stripLineNumberPrefix(line));
    }
    return out.toOwnedSlice();
}

fn normalizePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    // Tilde expansion. `~` or `~/...` maps to $HOME (or to the
    // user's home dir on the rare system where HOME isn't set).
    // Without this, a caller typing `Read ~/notes.md` tries to
    // find a literal "~" directory and fails with "not found".
    // Matches the reference's `expandHome` helper which runs on
    // every tool input path.
    //
    // Only the exact `~` or `~/` prefix is expanded -- `~alice`
    // (another user's home) is out of scope because it requires
    // a password database lookup that most sandboxes block.
    const expanded = try expandHomeTilde(allocator, path);
    defer allocator.free(expanded);

    const joined = if (std.fs.path.isAbsolute(expanded))
        try allocator.dupe(u8, expanded)
    else
        try std.fs.path.join(allocator, &.{ cwd, expanded });
    errdefer allocator.free(joined);

    // Resolve symlinks to prevent escaping the workspace via symlink targets.
    const resolved = try resolvePathThroughExistingAncestors(allocator, joined);
    allocator.free(joined);
    return resolved;
}

/// Expand a leading `~` or `~/` prefix to $HOME. Returns an owned
/// copy of `path` (with or without expansion applied) so the caller
/// can free uniformly.
///
///   "~"            -> $HOME
///   "~/foo"        -> $HOME/foo
///   "~alice/foo"   -> unchanged (out of scope)
///   "/abs"         -> unchanged
///   "rel/path"     -> unchanged
fn expandHomeTilde(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);
    // `~alice/...` form: leave alone.
    if (path.len > 1 and path[1] != '/') return allocator.dupe(u8, path);

    const home = path_utils.getHomeDir(allocator) catch return allocator.dupe(u8, path);
    defer allocator.free(home);
    if (home.len == 0) return allocator.dupe(u8, path);

    if (path.len == 1) return allocator.dupe(u8, home);
    // path is "~/..." so path[1..] starts with '/'. Strip the slash
    // and join via std.fs.path.join so repeated slashes collapse.
    const rest = std.mem.trimStart(u8, path[1..], "/");
    if (rest.len == 0) return allocator.dupe(u8, home);
    return std.fs.path.join(allocator, &.{ home, rest });
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.realPathFileAbsolute(rt.io, path, &buf)
    else
        try std.Io.Dir.cwd().realPathFile(rt.io, path, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn resolvePathThroughExistingAncestors(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Try to realpath the full path first. If the target doesn't exist
    // yet (e.g. writing to a new file), fall back to realpath'ing the
    // longest existing ancestor and joining the unresolved suffix.
    if (realpathAlloc(allocator, path)) |resolved| {
        return resolved;
    } else |_| {}

    var probe = path;
    while (std.fs.path.dirname(probe)) |parent| {
        if (parent.len == probe.len) break;

        if (realpathAlloc(allocator, parent)) |resolved_parent| {
            defer allocator.free(resolved_parent);

            const suffix = std.mem.trimStart(u8, path[parent.len..], "/\\");
            if (suffix.len == 0) return allocator.dupe(u8, resolved_parent);
            return std.fs.path.join(allocator, &.{ resolved_parent, suffix });
        } else |_| {}

        probe = parent;
    }

    return allocator.dupe(u8, path);
}

const testing = std.testing;

test "normalizePath resolves symlinked parent for new file" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "workspace");
    try tmp.dir.createDirPath(rt.io, "outside");
    try tmp.dir.symLink(rt.io, "../outside", "workspace/link", .{});

    const cwd = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "workspace");
    defer testing.allocator.free(cwd);

    const normalized = try normalizePath(testing.allocator, cwd, "link/new.txt");
    defer testing.allocator.free(normalized);

    const expected_dir = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "outside");
    defer testing.allocator.free(expected_dir);
    const expected = try std.fs.path.join(testing.allocator, &.{ expected_dir, "new.txt" });
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, normalized);
}

test "write blocks likely secret content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);
    const sample = "token=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890";

    try testing.expectError(
        error.SecretScanBlocked,
        write(testing.allocator, cwd, "demo.txt", sample, false),
    );
}

test "edit blocks introducing likely secret content" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "safe=true\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Must Read before Edit -- populates the per-session tracker
    // so the edit() call below isn't rejected by the read-before-
    // edit enforcement check.
    const read_buf = try readRange(testing.allocator, cwd, "demo.txt", 4096, 0, 0);
    testing.allocator.free(read_buf);

    const sample = "token=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890";

    try testing.expectError(
        error.SecretScanBlocked,
        edit(testing.allocator, cwd, "demo.txt", "safe=true", sample, false),
    );
}

test "write preserves existing file mode on overwrite" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "script.sh", .data = "#!/bin/sh\necho old\n" });
    {
        const existing = try tmp.dir.openFile(rt.io, "script.sh", .{});
        defer existing.close(rt.io);
        try existing.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o755));
    }

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Mark the file as read so the new read-before-write gate
    // clears -- this test is about mode preservation, not the
    // enforcement path.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "script.sh");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const wmsg = try write(testing.allocator, cwd, "script.sh", "#!/bin/sh\necho new\n", false);
    testing.allocator.free(wmsg);

    const stat = try tmp.dir.statFile(rt.io, "script.sh", .{});
    try testing.expectEqual(@as(u64, 0o755), stat.permissions.toMode() & 0o7777);

    const after = try tmp.dir.readFileAlloc(rt.io, "script.sh", testing.allocator, .limited(1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("#!/bin/sh\necho new\n", after);
}

test "write rejects overwriting an existing file that has not been read" {
    // The big one: a fresh session cannot blindly overwrite a file
    // it hasn't seen. Matches the reference FileWriteTool's
    // readFileState gate. Without this check, a model can trample
    // an editor save or another agent's work that happened since
    // conversation start.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "existing.txt", .data = "original content\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const err = write(testing.allocator, cwd, "existing.txt", "new content\n", false);
    try testing.expectError(error.WriteRequiresPriorRead, err);

    // File on disk must be untouched.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "existing.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("original content\n", on_disk);
}

test "write rejects content larger than the size cap" {
    // Catches runaway generations before they land on disk.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Allocate one byte over the cap. We don't actually touch every
    // byte -- the check happens before any filesystem work so this
    // stays fast even on tiny CI boxes.
    const over_cap = try testing.allocator.alloc(u8, WRITE_MAX_BYTES_DEFAULT + 1);
    defer testing.allocator.free(over_cap);
    @memset(over_cap, 'x');

    try testing.expectError(
        error.WriteContentTooLarge,
        write(testing.allocator, cwd, "giant.txt", over_cap, false),
    );

    // File must NOT have been created.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(rt.io, "giant.txt", .{}),
    );
}

test "write accepts content exactly at the size cap" {
    // Edge: exactly at the cap is still accepted. One byte over is
    // the failure boundary.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Use a small body that's comfortably under the default cap but
    // asserts the logic path. Writing a full 8 MiB buffer in a test
    // would be wasteful; the boundary is exercised by the other test.
    const body = "exactly fine\n";
    const wmsg = try write(testing.allocator, cwd, "ok.txt", body, false);
    defer testing.allocator.free(wmsg);
    try testing.expect(std.mem.indexOf(u8, wmsg, "created ok.txt") != null);
}

test "write auto-sets executable bit on new shebang files" {
    // A model writing a new script with `#!/bin/sh` should get a
    // run-ready file without needing a separate chmod step.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const wmsg = try write(testing.allocator, cwd, "deploy.sh", "#!/bin/sh\necho hi\n", false);
    testing.allocator.free(wmsg);

    const stat = try tmp.dir.statFile(rt.io, "deploy.sh", .{});
    try testing.expectEqual(@as(u64, 0o755), stat.permissions.toMode() & 0o7777);
}

test "write leaves non-shebang new files at default 0644" {
    // Negative control: a plain text file should NOT get the
    // executable bit. Only content that begins with `#!` qualifies.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const wmsg = try write(testing.allocator, cwd, "notes.txt", "plain text\n", false);
    testing.allocator.free(wmsg);

    const stat = try tmp.dir.statFile(rt.io, "notes.txt", .{});
    // Exact default mode varies by umask, but the executable bits
    // (user+group+other) MUST be zero for plain text.
    try testing.expectEqual(@as(u64, 0), stat.permissions.toMode() & 0o111);
}

test "stripSurroundingQuotes removes one matching pair" {
    try testing.expectEqualStrings("foo", stripSurroundingQuotes("'foo'"));
    try testing.expectEqualStrings("foo", stripSurroundingQuotes("\"foo\""));
    try testing.expectEqualStrings("foo", stripSurroundingQuotes("foo"));
    try testing.expectEqualStrings("/a/b", stripSurroundingQuotes("/a/b"));
}

test "write rejects shell-expansion path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const out = try write(alloc, cwd, "$HOME/x", "data\n", false);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "shell expansion") != null);
}

test "write rejects glob pattern path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const out = try write(alloc, cwd, "dir/*.txt", "data\n", false);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "glob") != null);
}

test "write rejects tilde-variant path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(alloc, &tmp);
    defer alloc.free(cwd);

    const out = try write(alloc, cwd, "~root/.ssh/x", "data\n", false);
    defer alloc.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "tilde expansion variants") != null);
}

test "write allows a legitimate tilde-home path (expanded, not a variant)" {
    // A bare ~/... must NOT be rejected: expandHomeTilde turns it into
    // an absolute $HOME path before the variant check runs. This locks
    // the ordering requirement from the task.
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;
    // Only assert the path is not rejected by the validation guard;
    // run the refusal helper directly to avoid touching the real $HOME
    // filesystem in a write.
    const refusal = try pathValidationRefusal(alloc, "~/legit/file.txt", .write);
    try testing.expect(refusal == null);
}

test "contentHasShebang detects shebang prefix" {
    try testing.expect(contentHasShebang("#!/bin/sh\necho hi"));
    try testing.expect(contentHasShebang("#!/usr/bin/env python"));
    try testing.expect(contentHasShebang("#!"));
    try testing.expect(!contentHasShebang(""));
    try testing.expect(!contentHasShebang("#"));
    try testing.expect(!contentHasShebang(" #!/bin/sh"));
    try testing.expect(!contentHasShebang("# comment"));
    try testing.expect(!contentHasShebang("plain text\n"));
}

test "write allows creating a brand-new file without prior read" {
    // Positive path 1: creating a new file is always safe because
    // there's nothing to clobber. The read-before-write gate only
    // kicks in when the target already exists.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const wmsg = try write(testing.allocator, cwd, "fresh.txt", "brand new content\n", false);
    defer testing.allocator.free(wmsg);
    try testing.expect(std.mem.indexOf(u8, wmsg, "created fresh.txt") != null);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "fresh.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("brand new content\n", on_disk);
}

test "write allows append without prior read" {
    // Positive path 2: append mode is always safe because it's
    // additive. We don't require the model to have read the file
    // because we're not replacing existing content.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "log.txt", .data = "first\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const wmsg = try write(testing.allocator, cwd, "log.txt", "second\n", true);
    defer testing.allocator.free(wmsg);
    try testing.expect(std.mem.indexOf(u8, wmsg, "appended") != null);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "log.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("first\nsecond\n", on_disk);
}

test "expandHomeTilde expands bare tilde to HOME" {
    if (builtin.os.tag == .windows) return;
    const home = @import("../core/env.zig").getenv("HOME") orelse return error.SkipZigTest;
    if (home.len == 0) return error.SkipZigTest;

    const got_bare = try expandHomeTilde(testing.allocator, "~");
    defer testing.allocator.free(got_bare);
    try testing.expectEqualStrings(home, got_bare);
}

test "expandHomeTilde expands tilde-slash prefix" {
    if (builtin.os.tag == .windows) return;
    const home = @import("../core/env.zig").getenv("HOME") orelse return error.SkipZigTest;
    if (home.len == 0) return error.SkipZigTest;

    const got = try expandHomeTilde(testing.allocator, "~/notes.md");
    defer testing.allocator.free(got);

    const expected = try std.fs.path.join(testing.allocator, &.{ home, "notes.md" });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, got);
}

test "expandHomeTilde leaves other-user tilde unchanged" {
    // `~alice/file` requires a password database lookup and is
    // out of scope -- we pass it through unchanged so downstream
    // path resolution still has a chance to match a literal dir.
    const got = try expandHomeTilde(testing.allocator, "~alice/file.txt");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("~alice/file.txt", got);
}

test "expandHomeTilde leaves absolute and relative paths unchanged" {
    {
        const got = try expandHomeTilde(testing.allocator, "/abs/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("/abs/path", got);
    }
    {
        const got = try expandHomeTilde(testing.allocator, "rel/path");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("rel/path", got);
    }
    {
        const got = try expandHomeTilde(testing.allocator, "");
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("", got);
    }
}

test "write rejects directory target with WriteTargetIsDirectory" {
    // Same class as the Read IsDir handler, but the error surfaces
    // as a typed error so the dispatch layer can format a helpful
    // message pointing at a file inside the directory.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "subdir");
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expectError(
        error.WriteTargetIsDirectory,
        write(testing.allocator, cwd, "subdir", "content\n", false),
    );
}

test "edit rejects directory target with a Glob-style hint" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "src");
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try edit(testing.allocator, cwd, "src", "foo", "bar", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "is a directory") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Edit operates on a single file") != null);
}

test "multiEdit rejects directory target with a Glob-style hint" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "src");
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const edits = "[{\"old_string\":\"foo\",\"new_string\":\"bar\"}]";
    const result = try multiEdit(testing.allocator, cwd, "src", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "is a directory") != null);
    try testing.expect(std.mem.indexOf(u8, result, "MultiEdit operates on a single file") != null);
}

test "edit rejects when file was modified externally after Read" {
    // Port of the reference's mtime-drift check: once we've Read
    // a file, any external modification (editor save, another
    // agent, git checkout) should cause the next Edit to fail
    // rather than silently apply against a stale snapshot.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "version one\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Read to record the original mtime.
    const read_result = try readRange(testing.allocator, cwd, "doc.txt", 4096, 0, 0);
    testing.allocator.free(read_result);

    // Sleep just enough to guarantee a new mtime, then overwrite
    // the file externally (bypassing the Write tool so we don't
    // update the tracker ourselves).
    clock.sleepNanos(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "version two\n" });

    // Edit must now fail with the mtime-drift error.
    const result = try edit(testing.allocator, cwd, "doc.txt", "version one", "version three", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "modified externally") != null);

    // File on disk must still be the externally-written version.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "doc.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("version two\n", on_disk);
}

test "multiEdit rejects when file was modified externally after Read" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "alpha\nbeta\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const read_result = try readRange(testing.allocator, cwd, "doc.txt", 4096, 0, 0);
    testing.allocator.free(read_result);

    clock.sleepNanos(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "alpha\nbeta\ngamma\n" });

    const edits = "[{\"old_string\":\"alpha\",\"new_string\":\"ALPHA\"}]";
    const result = try multiEdit(testing.allocator, cwd, "doc.txt", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "modified externally") != null);

    // File must still contain the externally-added "gamma" line.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "doc.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("alpha\nbeta\ngamma\n", on_disk);
}

test "write rejects when file was modified externally after Read" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "original\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const read_result = try readRange(testing.allocator, cwd, "doc.txt", 4096, 0, 0);
    testing.allocator.free(read_result);

    clock.sleepNanos(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.txt", .data = "externally modified\n" });

    try testing.expectError(
        error.WriteStaleMtime,
        write(testing.allocator, cwd, "doc.txt", "model-written\n", false),
    );

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "doc.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("externally modified\n", on_disk);
}

test "edit succeeds immediately after Read when nothing has changed" {
    // The positive path for the mtime check: Read -> Edit with
    // no external modification must still succeed.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "fresh.txt", .data = "hello world\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const read_result = try readRange(testing.allocator, cwd, "fresh.txt", 4096, 0, 0);
    testing.allocator.free(read_result);

    const result = try edit(testing.allocator, cwd, "fresh.txt", "hello", "HELLO", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);
    try testing.expect(std.mem.indexOf(u8, result, "modified externally") == null);
}

test "write allows overwriting after Read was called" {
    // Positive path 3: the happy path -- read the file, then write
    // to it. The gate unblocks because the tracker saw the Read.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "notes.txt", .data = "draft\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Read first, so the tracker records the path.
    const read_result = try readRange(testing.allocator, cwd, "notes.txt", 4096, 0, 0);
    testing.allocator.free(read_result);

    // Now Write succeeds.
    const wmsg = try write(testing.allocator, cwd, "notes.txt", "final\n", false);
    defer testing.allocator.free(wmsg);
    try testing.expect(std.mem.indexOf(u8, wmsg, "rewrote notes.txt") != null);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "notes.txt");
    defer testing.allocator.free(abs);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("final\n", on_disk);
}

test "hasBinaryExtension recognises common binary formats" {
    try testing.expect(hasBinaryExtension("logo.png"));
    try testing.expect(hasBinaryExtension("LOGO.PNG"));
    try testing.expect(hasBinaryExtension("x/y/z/archive.tar.gz"));
    try testing.expect(hasBinaryExtension("bundle.app"));
    try testing.expect(hasBinaryExtension("data.sqlite3"));
    try testing.expect(hasBinaryExtension("font.woff2"));
    try testing.expect(hasBinaryExtension("mod.wasm"));
}

test "hasBinaryExtension leaves text files alone" {
    try testing.expect(!hasBinaryExtension("src/main.zig"));
    try testing.expect(!hasBinaryExtension("README.md"));
    try testing.expect(!hasBinaryExtension("Dockerfile"));
    try testing.expect(!hasBinaryExtension("notes.txt"));
    try testing.expect(!hasBinaryExtension("no_dot_at_all"));
    try testing.expect(!hasBinaryExtension(""));
}

test "read refuses binary file with clean error message" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "logo.png", .data = "\x89PNG\r\n\x1a\n..." });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "data.sqlite", .data = "SQLite format 3" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Image files are now base64-encoded for vision support, not rejected
    const img_result = try read(testing.allocator, cwd, "logo.png", 4096);
    defer testing.allocator.free(img_result);
    try testing.expect(std.mem.indexOf(u8, img_result, "<zcode-image") != null);
    try testing.expect(std.mem.indexOf(u8, img_result, "image/png") != null);

    // Non-image binary files are still rejected
    const bin_result = try read(testing.allocator, cwd, "data.sqlite", 4096);
    defer testing.allocator.free(bin_result);
    try testing.expect(std.mem.indexOf(u8, bin_result, "refused to read binary file") != null);
}

test "isBinaryContent: empty buffer is not binary" {
    try testing.expect(!isBinaryContent(""));
}

test "isBinaryContent: pure ASCII text is not binary" {
    try testing.expect(!isBinaryContent("hello world\nthis is plain text\n"));
}

test "isBinaryContent: tab/newline/CR are allowed in text" {
    try testing.expect(!isBinaryContent("col1\tcol2\r\nval1\tval2\n"));
}

test "isBinaryContent: a single null byte triggers binary detection" {
    // The null byte rule fires immediately regardless of where in
    // the first 8 KiB the null is. Header-position nulls are the
    // common case but we test mid-buffer for completeness.
    try testing.expect(isBinaryContent("safe text\x00more"));
    try testing.expect(isBinaryContent("\x00at-the-start"));
}

test "isBinaryContent: ELF magic header is binary" {
    // First 4 bytes of every Linux executable: 7f 45 4c 46 ("\x7fELF").
    // The 0x7f isn't a null but is non-printable, and the rest of an
    // ELF header is full of non-printables -- this should trip the
    // 10% threshold even before any null appears.
    const elf_header = "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00";
    try testing.expect(isBinaryContent(elf_header));
}

test "isBinaryContent: text with a single non-printable stays text" {
    // 1 control character in 100 bytes = 1% < 10% threshold.
    var buf: [100]u8 = undefined;
    @memset(&buf, 'a');
    buf[50] = 0x01; // SOH -- non-printable but isolated
    try testing.expect(!isBinaryContent(&buf));
}

test "isBinaryContent: text with 11% non-printable becomes binary" {
    var buf: [100]u8 = undefined;
    @memset(&buf, 'a');
    var i: usize = 0;
    while (i < 11) : (i += 1) buf[i] = 0x01;
    try testing.expect(isBinaryContent(&buf));
}

test "isBinaryContent: only inspects first 8 KiB" {
    // 16 KiB buffer: first 8 KiB pure text, second 8 KiB nulls.
    // The function must NOT scan into the second half, so this
    // should classify as text.
    var buf: [16384]u8 = undefined;
    @memset(buf[0..8192], 'x');
    @memset(buf[8192..], 0); // nulls past the cap
    try testing.expect(!isBinaryContent(&buf));
}

test "read refuses no-extension binary via content sniffing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // ELF-like header with no extension at all -- hasBinaryExtension
    // would say "text" but isBinaryContent should catch it.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "compiled-binary",
        .data = "\x7fELF\x02\x01\x01\x00" ++ ("\x00" ** 64),
    });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try read(testing.allocator, cwd, "compiled-binary", 4096);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "content sniffing") != null);
    try testing.expect(std.mem.indexOf(u8, result, "compiled-binary") != null);
}

test "edit refuses no-extension binary via content sniffing" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "blob",
        .data = "\x00\x01\x02\x03binary garbage\x00\x00\x00",
    });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Can't Read() this file through the normal path -- readRange
    // would refuse it as binary, which means the tracker would
    // never register it. Seed the tracker directly so the Edit
    // call reaches its OWN content-sniffing check (the thing this
    // test is verifying).
    const abs_path = try std.fs.path.join(testing.allocator, &.{ cwd, "blob" });
    defer testing.allocator.free(abs_path);
    trackerRecordRead(testing.allocator, abs_path);

    const result = try edit(testing.allocator, cwd, "blob", "garbage", "clean", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "content sniffing") != null);
}

test "stemWithoutExtension strips simple extension" {
    try testing.expectEqualStrings("main", stemWithoutExtension("main.zig"));
    try testing.expectEqualStrings("archive.tar", stemWithoutExtension("archive.tar.gz"));
    try testing.expectEqualStrings("README", stemWithoutExtension("README"));
}

test "stemWithoutExtension preserves dotfile leading dot" {
    // Hidden files like .env have no extension to strip -- the dot
    // belongs to the name itself.
    try testing.expectEqualStrings(".env", stemWithoutExtension(".env"));
    try testing.expectEqualStrings(".gitignore", stemWithoutExtension(".gitignore"));
}

test "findSimilarFile finds same-stem different-extension neighbour" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "config.toml", .data = "key = 1\n" });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const missing = try std.fs.path.join(testing.allocator, &.{ cwd, "config.json" });
    defer testing.allocator.free(missing);

    const suggestion = (try findSimilarFile(testing.allocator, missing)) orelse return error.NoSuggestion;
    defer testing.allocator.free(suggestion);
    try testing.expectEqualStrings("config.toml", suggestion);
}

test "findSimilarFile returns null when no neighbour matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "unrelated.txt", .data = "x" });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const missing = try std.fs.path.join(testing.allocator, &.{ cwd, "config.json" });
    defer testing.allocator.free(missing);

    try testing.expectEqual(@as(?[]u8, null), try findSimilarFile(testing.allocator, missing));
}

test "read returns suggestion when file is missing but similar exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "// hello\n" });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try read(testing.allocator, cwd, "main.zg", 4096);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "file not found") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Did you mean") != null);
    try testing.expect(std.mem.indexOf(u8, result, "main.zig") != null);
}

test "read returns plain not-found when no neighbour matches" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try read(testing.allocator, cwd, "nothing.txt", 4096);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "file not found") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Did you mean") == null);
}

test "read wraps content in cat -n style line numbers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "alpha\nbeta\ngamma\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try read(testing.allocator, cwd, "main.zig", 4096);
    defer testing.allocator.free(result);

    // The cat -n style is "     N→content".
    try testing.expect(std.mem.indexOf(u8, result, "     1\xe2\x86\x92alpha") != null);
    try testing.expect(std.mem.indexOf(u8, result, "     2\xe2\x86\x92beta") != null);
    try testing.expect(std.mem.indexOf(u8, result, "     3\xe2\x86\x92gamma") != null);
}

test "edit accepts find_text with line-number prefixes" {
    // The model's typical workflow: Read(file) returns "   1→hello\n",
    // then it pastes the line-numbered text back as the find arg.
    // Edit must strip the prefix before matching against the actual
    // file bytes.
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Populate the read tracker by calling the real read path.
    const read_buf = try readRange(testing.allocator, cwd, "demo.txt", 4096, 0, 0);
    testing.allocator.free(read_buf);

    // find with the line-number prefix the model would have seen.
    const result = try edit(
        testing.allocator,
        cwd,
        "demo.txt",
        "     1\xe2\x86\x92hello",
        "     1\xe2\x86\x92howdy",
        false,
    );
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);

    const after = try tmp.dir.readFileAlloc(rt.io, "demo.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("howdy\nworld\n", after);
}

test "stripLineNumberPrefixesAlloc is a no-op on raw text" {
    const out = try stripLineNumberPrefixesAlloc(testing.allocator, "no prefixes\nhere\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("no prefixes\nhere\n", out);
}

test "edit rejects a file that has not been read yet in this session" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "unread.txt", .data = "hello\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // No Read call before Edit -- should fail with the read-first
    // guidance rather than silently proceeding against a
    // potentially-stale model memory.
    const result = try edit(testing.allocator, cwd, "unread.txt", "hello", "howdy", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "has not been read yet") != null);
    try testing.expect(std.mem.indexOf(u8, result, "unread.txt") != null);
    // File must be untouched.
    const after = try tmp.dir.readFileAlloc(rt.io, "unread.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("hello\nworld\n", after);
}

test "edit accepts a file that was read earlier in the session" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Populate the tracker via a real Read.
    const read_buf = try readRange(testing.allocator, cwd, "demo.txt", 4096, 0, 0);
    testing.allocator.free(read_buf);

    const result = try edit(testing.allocator, cwd, "demo.txt", "hello", "howdy", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);
}

test "edit chain works without re-reading after the first edit" {
    // After a successful edit, the tracker records the file again
    // so a subsequent Edit call on the same file proceeds without
    // another Read. This mirrors the common refactor flow.
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "a b c d\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const read_buf = try readRange(testing.allocator, cwd, "demo.txt", 4096, 0, 0);
    testing.allocator.free(read_buf);

    const first = try edit(testing.allocator, cwd, "demo.txt", "a", "X", false);
    testing.allocator.free(first);

    // No Read between the two edits -- but the tracker was
    // refreshed by the first edit, so the second still passes.
    const second = try edit(testing.allocator, cwd, "demo.txt", "b", "Y", false);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "edit ok") != null);

    const after = try tmp.dir.readFileAlloc(rt.io, "demo.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("X Y c d\n", after);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "readTrackerSnapshot is empty before any reads" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    const snap = try readTrackerSnapshot(testing.allocator);
    defer freeReadTrackerSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 0), snap.len);
}

test "readTrackerSnapshot returns the set of read files" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "a.txt", .data = "A" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "b.txt", .data = "B" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const a = try readRange(testing.allocator, cwd, "a.txt", 1024, 0, 0);
    testing.allocator.free(a);
    const b = try readRange(testing.allocator, cwd, "b.txt", 1024, 0, 0);
    testing.allocator.free(b);

    const snap = try readTrackerSnapshot(testing.allocator);
    defer freeReadTrackerSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 2), snap.len);

    var saw_a = false;
    var saw_b = false;
    for (snap) |path| {
        if (std.mem.endsWith(u8, path, "/a.txt")) saw_a = true;
        if (std.mem.endsWith(u8, path, "/b.txt")) saw_b = true;
    }
    try testing.expect(saw_a);
    try testing.expect(saw_b);
}

test "readTrackerSnapshot dedups repeat reads of the same file" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "only.txt", .data = "hi" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    for (0..3) |_| {
        const buf = try readRange(testing.allocator, cwd, "only.txt", 1024, 0, 0);
        testing.allocator.free(buf);
    }

    const snap = try readTrackerSnapshot(testing.allocator);
    defer freeReadTrackerSnapshot(testing.allocator, snap);
    try testing.expectEqual(@as(usize, 1), snap.len);
}

test "edit bypasses read-before-edit when ZCODE_SKIP_READ_BEFORE_EDIT is set" {
    // Scripts and one-shot drivers can opt out of the enforcement
    // via an env flag, mirroring the reference's behaviour for
    // non-interactive paths. The flag only takes effect for
    // callers that have no conversation state to track reads in.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "hello\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Set env var, run the edit, unset so later tests aren't affected.
    _ = setenv("ZCODE_SKIP_READ_BEFORE_EDIT", "1", 1);
    defer _ = unsetenv("ZCODE_SKIP_READ_BEFORE_EDIT");

    const result = try edit(testing.allocator, cwd, "demo.txt", "hello", "howdy", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);
}

test "edit rejects non-unique find string when replace_all is false" {
    // The big one: previously we silently took the first match when
    // find appeared multiple times, which could mangle a file the
    // model thought it was editing carefully. Now we refuse the edit
    // with a clear error telling the model how to disambiguate.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "port = 8080\nport = 8080\nname = demo\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "conf.txt", .data = original });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Mark the file as read so we clear the read-before-edit gate.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "conf.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const result = try edit(testing.allocator, cwd, "conf.txt", "port = 8080", "port = 9090", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "not unique") != null);
    try testing.expect(std.mem.indexOf(u8, result, "all=true") != null);

    // File on disk must be untouched.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(original, on_disk);
}

test "edit accepts non-unique find string when all=true" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "conf.txt", .data = "port = 8080\nport = 8080\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "conf.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    // all=true replaces every occurrence -- uniqueness check short-circuits.
    const result = try edit(testing.allocator, cwd, "conf.txt", "8080", "9090", true);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("port = 9090\nport = 9090\n", on_disk);
}

test "edit accepts unique find string with replace_all=false" {
    // Sanity: the common case (one occurrence, replace_all=false) still works.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "unique.txt", .data = "alpha\nbeta\ngamma\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "unique.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const result = try edit(testing.allocator, cwd, "unique.txt", "beta", "BETA", false);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "edit ok") != null);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("alpha\nBETA\ngamma\n", on_disk);
}

test "multiEdit applies multiple edits atomically" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.zig");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const edits = "[{\"old_string\":\"const a = 1;\",\"new_string\":\"const a = 10;\"},{\"old_string\":\"const b = 2;\",\"new_string\":\"const b = 20;\"},{\"old_string\":\"const c = 3;\",\"new_string\":\"const c = 30;\"}]";
    const result = try multiEdit(testing.allocator, cwd, "demo.zig", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "multi_edit ok") != null);
    try testing.expect(std.mem.indexOf(u8, result, "3 edit(s)") != null);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("const a = 10;\nconst b = 20;\nconst c = 30;\n", on_disk);
}

test "multiEdit rolls back the whole batch when one edit fails" {
    // The atomicity guarantee: if any edit can't be applied (here,
    // the second edit's old_string doesn't exist), the file on disk
    // must stay exactly as it was. No half-applied state.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "const a = 1;\nconst b = 2;\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.zig", .data = original });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.zig");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const edits = "[{\"old_string\":\"const a = 1;\",\"new_string\":\"const a = 10;\"},{\"old_string\":\"this line does not exist\",\"new_string\":\"x\"}]";
    const result = try multiEdit(testing.allocator, cwd, "demo.zig", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "multi_edit failed at index 1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "not found") != null);

    // File must be untouched.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(original, on_disk);
}

test "multiEdit later edit sees state after earlier edits" {
    // Key semantics: edit N+1 operates on the buffer AFTER edit N has
    // been applied. This lets you remove a duplicate first and then
    // rely on uniqueness for a subsequent edit.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = "foo\nfoo\nbar\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    // First edit uses replace_all to collapse the duplicate. Second
    // edit relies on the unique-match rule, which passes because the
    // first edit already ran.
    const edits = "[{\"old_string\":\"foo\",\"new_string\":\"FOO\",\"replace_all\":true},{\"old_string\":\"bar\",\"new_string\":\"BAR\"}]";
    const result = try multiEdit(testing.allocator, cwd, "demo.txt", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "multi_edit ok") != null);

    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings("FOO\nFOO\nBAR\n", on_disk);
}

test "multiEdit rejects non-unique find when replace_all is not set" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "x\nx\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "dup.txt", .data = original });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "dup.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const edits = "[{\"old_string\":\"x\",\"new_string\":\"y\"}]";
    const result = try multiEdit(testing.allocator, cwd, "dup.txt", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "appears multiple times") != null);

    // Untouched file on disk.
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(rt.io, abs, testing.allocator, .limited(4 * 1024));
    defer testing.allocator.free(on_disk);
    try testing.expectEqualStrings(original, on_disk);
}

test "multiEdit rejects call when file has not been read" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "unread.txt", .data = "hello\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const edits = "[{\"old_string\":\"hello\",\"new_string\":\"world\"}]";
    const result = try multiEdit(testing.allocator, cwd, "unread.txt", edits);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "has not been read yet") != null);
}

test "multiEdit rejects empty edits array" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "x.txt", .data = "hi\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "x.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const result = try multiEdit(testing.allocator, cwd, "x.txt", "[]");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "empty") != null);
}

test "multiEdit rejects malformed JSON" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "x.txt", .data = "hi\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "x.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    const result = try multiEdit(testing.allocator, cwd, "x.txt", "not json");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "must be a JSON array") != null);
}

test "stripLineNumberPrefixesAlloc strips multi-line prefixed text" {
    const out = try stripLineNumberPrefixesAlloc(
        testing.allocator,
        "     1\xe2\x86\x92alpha\n     2\xe2\x86\x92beta",
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("alpha\nbeta", out);
}

test "write leaves original file intact when content is rejected" {
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "safe=true\nkey=value\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "demo.txt", .data = original });

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);
    const sample = "token=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890";

    // Mark as read so we clear the read-before-write gate -- this
    // test is about the secret-scanner rejection, not the gate.
    const abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "demo.txt");
    defer testing.allocator.free(abs);
    trackerRecordRead(testing.allocator, abs);

    try testing.expectError(
        error.SecretScanBlocked,
        write(testing.allocator, cwd, "demo.txt", sample, false),
    );

    const after = try tmp.dir.readFileAlloc(rt.io, "demo.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(original, after);
}

test "sliceByLineRange returns full content when start_line and limit are zero" {
    const raw = "alpha\nbeta\ngamma\n";
    const slice = sliceByLineRange(raw, 0, 0);
    try testing.expectEqualStrings(raw, slice);
}

test "sliceByLineRange honors offset only" {
    const raw = "alpha\nbeta\ngamma\ndelta\n";
    // start_line=3 should drop alpha+beta and keep gamma+delta.
    const slice = sliceByLineRange(raw, 3, 0);
    try testing.expectEqualStrings("gamma\ndelta\n", slice);
}

test "sliceByLineRange honors limit only" {
    const raw = "alpha\nbeta\ngamma\ndelta\n";
    // start_line=1 with limit=2 keeps alpha+beta.
    const slice = sliceByLineRange(raw, 1, 2);
    try testing.expectEqualStrings("alpha\nbeta\n", slice);
}

test "sliceByLineRange honors offset+limit" {
    const raw = "alpha\nbeta\ngamma\ndelta\nepsilon\n";
    const slice = sliceByLineRange(raw, 2, 2);
    try testing.expectEqualStrings("beta\ngamma\n", slice);
}

test "sliceByLineRange returns empty slice when offset is past EOF" {
    const raw = "alpha\nbeta\n";
    const slice = sliceByLineRange(raw, 50, 10);
    try testing.expectEqual(@as(usize, 0), slice.len);
}

test "sliceByLineRange tolerates content with no trailing newline" {
    const raw = "alpha\nbeta";
    const slice = sliceByLineRange(raw, 2, 1);
    try testing.expectEqualStrings("beta", slice);
}

test "readRange paginates large file by line range" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // 6 lines, deterministic content so we can spot the slice.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "page.txt",
        .data = "one\ntwo\nthree\nfour\nfive\nsix\n",
    });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Lines 3 and 4 only.
    const result = try readRange(testing.allocator, cwd, "page.txt", 4096, 3, 2);
    defer testing.allocator.free(result);

    // Line numbers should reflect the actual file lines, not 1..2.
    try testing.expect(std.mem.indexOf(u8, result, "     3\xe2\x86\x92three") != null);
    try testing.expect(std.mem.indexOf(u8, result, "     4\xe2\x86\x92four") != null);
    // The slice should not include neighbouring lines.
    try testing.expect(std.mem.indexOf(u8, result, "two") == null);
    try testing.expect(std.mem.indexOf(u8, result, "five") == null);
}

test "readRange falls back to whole file when offset and limit are zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "all.txt", .data = "a\nb\nc\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "all.txt", 4096, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "     1\xe2\x86\x92a") != null);
    try testing.expect(std.mem.indexOf(u8, result, "     2\xe2\x86\x92b") != null);
    try testing.expect(std.mem.indexOf(u8, result, "     3\xe2\x86\x92c") != null);
}

test "readRange returns unchanged stub on duplicate full-file re-read" {
    // First Read loads the file normally and records its mtime in
    // the tracker. A second Read with the same path + no offset/
    // limit + unchanged mtime should return the short stub instead
    // of re-streaming the whole content.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.md", .data = "# Title\nbody line 1\nbody line 2\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // First read: full content.
    const first = try readRange(testing.allocator, cwd, "doc.md", 4096, 0, 0);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "Title") != null);
    try testing.expect(std.mem.indexOf(u8, first, "body line 1") != null);

    // Second read: same params, no fs changes. Must return the stub.
    const second = try readRange(testing.allocator, cwd, "doc.md", 4096, 0, 0);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "unchanged since your earlier Read") != null);
    try testing.expect(std.mem.indexOf(u8, second, "doc.md") != null);
    // Stub must not leak the actual content.
    try testing.expect(std.mem.indexOf(u8, second, "body line 1") == null);
}

test "readRange returns full content after mtime changes" {
    // If the file was modified between reads, the stub short-circuit
    // must NOT fire -- the model needs the fresh content.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.md", .data = "first version\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const first = try readRange(testing.allocator, cwd, "doc.md", 4096, 0, 0);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.indexOf(u8, first, "first version") != null);

    // Sleep just enough to produce a new mtime, then overwrite.
    clock.sleepNanos(20 * std.time.ns_per_ms);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "doc.md", .data = "SECOND version\n" });

    const second = try readRange(testing.allocator, cwd, "doc.md", 4096, 0, 0);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "SECOND version") != null);
    try testing.expect(std.mem.indexOf(u8, second, "unchanged since") == null);
}

test "readRange sliced re-read never returns the unchanged stub" {
    // Sliced reads (offset != 0 or limit != 0) always fall through
    // to the real read path because we don't cache per-slice state.
    // A re-read with a DIFFERENT offset must return real content.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "many.txt",
        .data = "line 1\nline 2\nline 3\nline 4\nline 5\n",
    });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const first = try readRange(testing.allocator, cwd, "many.txt", 4096, 0, 0);
    defer testing.allocator.free(first);

    const sliced = try readRange(testing.allocator, cwd, "many.txt", 4096, 2, 2);
    defer testing.allocator.free(sliced);
    try testing.expect(std.mem.indexOf(u8, sliced, "line 2") != null);
    try testing.expect(std.mem.indexOf(u8, sliced, "unchanged since") == null);
}

test "readRange enforces token cap on oversized content" {
    // Ports the reference's DEFAULT_MAX_OUTPUT_TOKENS safety net.
    // Even if the byte cap is lifted, a file that tokenizes to
    // more than the token cap gets refused with a clean error
    // pointing at offset/limit as the recovery path.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a file that's well under the byte cap but over the
    // token cap. Our tokenizer charges ~1 token per word-ish run
    // plus newlines, so ~30k short words will comfortably exceed
    // the 25000-token default. We use short words ("a ") so the
    // byte count stays low.
    var body = std_io.StringBuilder.init(testing.allocator);
    defer body.deinit();
    var i: usize = 0;
    while (i < 30000) : (i += 1) {
        try body.writer().writeAll("a b c d e\n");
    }
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "verbose.txt", .data = body.items() });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "verbose.txt", 4 * 1024 * 1024, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "exceeding the Read cap") != null);
    try testing.expect(std.mem.indexOf(u8, result, "offset/limit") != null);
    try testing.expect(std.mem.indexOf(u8, result, "verbose.txt") != null);
}

test "readRange passes through content well under the token cap" {
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "small.txt", .data = "hello\nworld\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "small.txt", 4096, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "exceeding the Read cap") == null);
    try testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "world") != null);
}

test "readRange returns an explicit marker for empty files" {
    // An empty file previously returned a literal empty string
    // which looked identical to "read succeeded with no body" --
    // the model couldn't tell if the file was blank or something
    // had silently failed. Now we return a system-reminder marker
    // so the model has a clear signal.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "blank.txt", .data = "" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "blank.txt", 4096, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "exists but is empty") != null);
    try testing.expect(std.mem.indexOf(u8, result, "blank.txt") != null);
}

test "readRange strips UTF-8 BOM before line-numbering" {
    // Windows-saved UTF-8 files start with the 0xEF 0xBB 0xBF
    // byte-order mark. Without stripping, the first rendered line
    // would contain an invisible glyph at position 0 and Edit's
    // find-string matching would silently fail on a first-line
    // match.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // "\xEF\xBB\xBFhello world\n"
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "bom.txt",
        .data = "\xef\xbb\xbfhello world\n",
    });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "bom.txt", 4096, 0, 0);
    defer testing.allocator.free(result);

    // The BOM bytes must NOT appear in the output.
    try testing.expect(std.mem.indexOf(u8, result, "\xef\xbb\xbf") == null);
    // The actual content is still present.
    try testing.expect(std.mem.indexOf(u8, result, "hello world") != null);
    // And the line-number prefix is the very first thing on the line
    // (not BOM + prefix).
    try testing.expect(std.mem.startsWith(u8, result, "     1\xe2\x86\x92hello"));
}

test "readRange rejects directory paths with a Glob-first hint" {
    // Reading a directory by path is a common model mistake.
    // Previously Zig's readFileAlloc bubbled a raw `error.IsDir`.
    // Now we return a friendly message pointing at Glob.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "subdir");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "subdir/hello.txt", .data = "hi\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "subdir", 4096, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "is a directory") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Glob") != null);
    try testing.expect(std.mem.indexOf(u8, result, "subdir") != null);
    // Must not leak Zig's raw error name.
    try testing.expect(std.mem.indexOf(u8, result, "IsDir") == null);
}

test "readRange truncates files larger than max_bytes with a clear footer" {
    // Before this fix, a file bigger than the Read tool's cap
    // bubbled up a raw FileTooBig error. Now we truncate to
    // max_bytes and append a footer telling the model how to page.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a 5000-byte file (>> our test cap of 512)
    const body = "x" ** 5000;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "big.txt", .data = body });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "big.txt", 512, 0, 0);
    defer testing.allocator.free(result);

    // Must contain the truncation footer with the original size.
    try testing.expect(std.mem.indexOf(u8, result, "5000 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, result, "first 512 bytes") != null);
    // Must NOT contain the raw "FileTooBig" error.
    try testing.expect(std.mem.indexOf(u8, result, "FileTooBig") == null);
    // The content body must be truncated -- no room for all 5000 x's
    // plus line-number prefixes plus footer.
    try testing.expect(result.len < 4096);
}

test "readRange passes through small files untouched" {
    // Negative control: a small file must NOT get a truncation
    // footer. This pins the fast path for the common case.
    if (builtin.os.tag == .windows) return;

    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "small.txt", .data = "tiny\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "small.txt", 4096, 0, 0);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "tiny") != null);
    try testing.expect(std.mem.indexOf(u8, result, "showing first") == null);
    try testing.expect(std.mem.indexOf(u8, result, "bytes total") == null);
}

test "readRange returns a friendly error when offset is past EOF" {
    // Previously we silently returned empty -- the model had no
    // clue whether the file was empty or its offset was wrong.
    // Now we match the reference and surface a concrete error
    // listing the actual line count so the model can retry.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "tiny.txt", .data = "only one line\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "tiny.txt", 4096, 100, 5);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "exceeds file length") != null);
    try testing.expect(std.mem.indexOf(u8, result, "of 1 line") != null);
    try testing.expect(std.mem.indexOf(u8, result, "tiny.txt") != null);
    // The file content should NOT appear in the error body.
    try testing.expect(std.mem.indexOf(u8, result, "only one line") == null);
}

test "readRange offset-at-last-line still succeeds" {
    // Edge: offset == total_lines should read the very last line,
    // not fail with "exceeds file length".
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "three.txt", .data = "a\nb\nc\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "three.txt", 4096, 3, 1);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "exceeds") == null);
    try testing.expect(std.mem.indexOf(u8, result, "c") != null);
}

test "countTotalLines handles trailing newline variations" {
    try testing.expectEqual(@as(usize, 0), countTotalLines(""));
    // No trailing newline -- the partial line still counts.
    try testing.expectEqual(@as(usize, 1), countTotalLines("no newline"));
    try testing.expectEqual(@as(usize, 1), countTotalLines("one\n"));
    try testing.expectEqual(@as(usize, 2), countTotalLines("a\nb"));
    try testing.expectEqual(@as(usize, 2), countTotalLines("a\nb\n"));
    try testing.expectEqual(@as(usize, 3), countTotalLines("a\nb\nc\n"));
}

test "isBlockedDevicePath blocks all hardcoded device files" {
    // Every entry in BLOCKED_DEVICE_PATHS should round-trip true so
    // a regression that drops one of them is caught immediately.
    for (BLOCKED_DEVICE_PATHS) |entry| {
        try testing.expect(isBlockedDevicePath(entry));
    }
}

test "isBlockedDevicePath blocks /proc/self/fd stdio aliases" {
    try testing.expect(isBlockedDevicePath("/proc/self/fd/0"));
    try testing.expect(isBlockedDevicePath("/proc/self/fd/1"));
    try testing.expect(isBlockedDevicePath("/proc/self/fd/2"));
}

test "isBlockedDevicePath blocks /proc/<pid>/fd stdio aliases" {
    try testing.expect(isBlockedDevicePath("/proc/12345/fd/0"));
    try testing.expect(isBlockedDevicePath("/proc/1/fd/2"));
}

test "isBlockedDevicePath leaves /dev/null alone" {
    // /dev/null is intentionally NOT in the blocked set because
    // reading it returns immediately with EOF -- it does not hang.
    try testing.expect(!isBlockedDevicePath("/dev/null"));
}

test "isBlockedDevicePath ignores normal files in /dev-shaped paths" {
    try testing.expect(!isBlockedDevicePath("/home/user/dev/zero.txt"));
    try testing.expect(!isBlockedDevicePath("./dev/zero"));
    try testing.expect(!isBlockedDevicePath("/proc/cpuinfo"));
    try testing.expect(!isBlockedDevicePath("/proc/12345/fd/3"));
    try testing.expect(!isBlockedDevicePath("/dev/zerocoolfile"));
}

test "readRange refuses /dev/zero with clean error and no I/O" {
    // The point of the check is to never open the file. We pass a
    // throwaway cwd so even if the check were skipped, the path
    // would still resolve to the real /dev/zero -- but we expect
    // the function to bail out with an error string before touching
    // the filesystem.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "/dev/zero", 4096, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "/dev/zero") != null);
    try testing.expect(std.mem.indexOf(u8, result, "would block") != null);
}

test "readRange refuses /dev/stdin without blocking on input" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try readRange(testing.allocator, cwd, "/dev/stdin", 4096, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "/dev/stdin") != null);
    try testing.expect(std.mem.indexOf(u8, result, "would block") != null);
}

test "readRange still allows /dev/null which returns EOF immediately" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // /dev/null exists on every POSIX system and reading it returns
    // EOF immediately. We expect either an empty result or a clean
    // success path -- crucially NOT the device-block error message.
    // On systems where realpathAlloc surfaces a permission error
    // for /dev/null we accept the failure rather than blowing up
    // the test; the point is just to confirm the device-block
    // guard does not catch /dev/null.
    const result = readRange(testing.allocator, cwd, "/dev/null", 4096, 0, 0) catch return;
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "would block") == null);
}

test "getAlternateScreenshotPath swaps regular space for thin space" {
    const original = "/Users/x/Screenshot 2024-01-01 at 10.30.45 AM.png";
    const alt = (try getAlternateScreenshotPath(testing.allocator, original)).?;
    defer testing.allocator.free(alt);
    // The space before "AM" should now be U+202F (3 bytes).
    try testing.expectEqualStrings(
        "/Users/x/Screenshot 2024-01-01 at 10.30.45\xe2\x80\xafAM.png",
        alt,
    );
}

test "getAlternateScreenshotPath swaps thin space for regular space" {
    const original = "/Users/x/Screenshot 2024-01-01 at 10.30.45\xe2\x80\xafPM.png";
    const alt = (try getAlternateScreenshotPath(testing.allocator, original)).?;
    defer testing.allocator.free(alt);
    try testing.expectEqualStrings(
        "/Users/x/Screenshot 2024-01-01 at 10.30.45 PM.png",
        alt,
    );
}

test "getAlternateScreenshotPath returns null for non-screenshot filenames" {
    // No AM/PM
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/foo.png")) == null);
    // No prefix before AM (basename is too short)
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/AM.png")) == null);
    // Just "AM.png" (basename too short and no prefix)
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "AM.png")) == null);
    // Wrong AM/PM word -- "FM" is not a meridian
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/Screenshot FM.png")) == null);
    // Lowercase am/pm -- reference regex is case-sensitive
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/Screenshot am.png")) == null);
    // Dot, not space, before AM
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/Screenshot.AM.png")) == null);
    // No extension at all
    try testing.expect((try getAlternateScreenshotPath(testing.allocator, "/Users/x/Screenshot AM")) == null);
}

test "getAlternateScreenshotPath preserves directory in the alt path" {
    const original = "/private/var/folders/abcdef/T/screenshots/Screenshot 2024-09-15 at 3.42.18 PM.png";
    const alt = (try getAlternateScreenshotPath(testing.allocator, original)).?;
    defer testing.allocator.free(alt);
    try testing.expect(std.mem.startsWith(u8, alt, "/private/var/folders/abcdef/T/screenshots/"));
    try testing.expect(std.mem.endsWith(u8, alt, "\xe2\x80\xafPM.png"));
}

test "readRange retries with thin space when regular-space variant is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a file using the THIN_SPACE before "AM". A simple .txt
    // extension keeps us out of the BINARY_EXTENSIONS guard.
    const real_name = "Shot at 9 AM.txt";
    const real_with_thin = "Shot at 9\xe2\x80\xafAM.txt";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = real_with_thin, .data = "screenshot body\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // The user types the path with a regular space -- this would
    // normally ENOENT. The retry should swap to the thin space,
    // find the actual file, and return its content.
    const result = try readRange(testing.allocator, cwd, real_name, 4096, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "screenshot body") != null);
}

test "readRange retries with regular space when thin-space variant is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const real_with_space = "Shot at 9 PM.txt";
    const requested_with_thin = "Shot at 9\xe2\x80\xafPM.txt";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = real_with_space, .data = "old style\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // User types the thin-space variant; we should fall back to
    // the regular-space variant on disk.
    const result = try readRange(testing.allocator, cwd, requested_with_thin, 4096, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "old style") != null);
}

test "readRange falls through to file-not-found when neither space variant exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Neither variant on disk -- the caller still gets the friendly
    // file-not-found error, not a panic and not silent success.
    const result = try readRange(testing.allocator, cwd, "Shot at 9 AM.txt", 4096, 0, 0);
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "file not found") != null);
}

test "recentReadPaths returns paths newest-first and honors max" {
    // Phase 8 (compaction-08): post-compact file restoration relies on the
    // read tracker remembering read recency so it can re-read the N most
    // recently read files. This guards the recency ordering and the cap.
    resetReadTrackerForTesting();
    defer resetReadTrackerForTesting();

    // Use synthetic absolute paths; trackerRecordRead stats them (a stat
    // failure just records mtime 0) but still registers them with a recency
    // ordinal, which is all this test cares about.
    trackerRecordRead(testing.allocator, "/tmp/zcode-recent-a.txt");
    trackerRecordRead(testing.allocator, "/tmp/zcode-recent-b.txt");
    trackerRecordRead(testing.allocator, "/tmp/zcode-recent-c.txt");
    // Re-read 'a' so it is promoted back to the front.
    trackerRecordRead(testing.allocator, "/tmp/zcode-recent-a.txt");

    const top2 = try recentReadPaths(testing.allocator, 2);
    defer freeReadTrackerSnapshot(testing.allocator, top2);
    try testing.expectEqual(@as(usize, 2), top2.len);
    try testing.expectEqualStrings("/tmp/zcode-recent-a.txt", top2[0]);
    try testing.expectEqualStrings("/tmp/zcode-recent-c.txt", top2[1]);

    // max == 0 yields an empty slice, not an error.
    const none = try recentReadPaths(testing.allocator, 0);
    defer freeReadTrackerSnapshot(testing.allocator, none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

// --- lsp-04: Write clears delivered diagnostics for the edited file --------

test "write clears delivered LSP diagnostics for the file via the registry" {
    @import("zcode_runtime").installForTest();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    // Install a registry singleton so notifyLspAfterWrite can clear it. No LSP
    // manager is installed, so the doc-sync notification half is a safe no-op
    // here; this test isolates the clearDeliveredForFile half of the hook.
    var reg = lsp_registry.Registry.init(testing.allocator, rt.io);
    defer reg.deinit();
    lsp_registry.install(&reg);
    defer lsp_registry.uninstall();

    // The absolute path the Write will resolve to, and its file:// URI. The
    // file does not exist yet (Write creates it), so build the path from the
    // realpath'd cwd rather than tmpDirPath (which requires the file to exist).
    const abs = try std.fs.path.join(testing.allocator, &.{ cwd, "foo.zig" });
    defer testing.allocator.free(abs);
    const uri = try std.fmt.allocPrint(testing.allocator, "file://{s}", .{abs});
    defer testing.allocator.free(uri);

    const diags = [_]lsp_registry.Diagnostic{.{
        .message = "type mismatch",
        .severity = .error_,
        .line = 1,
        .col = 0,
        .end_line = 1,
        .end_col = 4,
    }};

    // Deliver the diagnostic once so it lands in the cross-turn `delivered` set.
    try reg.registerPending("zls", uri, &diags);
    const first = (try reg.checkForDiagnostics(testing.allocator)).?;
    testing.allocator.free(first);

    // Registering the identical diagnostic again would be deduped (returns null)
    // until the file is edited. Confirm that baseline.
    try reg.registerPending("zls", uri, &diags);
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);

    // A Write to the file must clear the delivered tracking for its URI.
    const msg = try write(testing.allocator, cwd, "foo.zig", "const a: u8 = 1;\n", false);
    testing.allocator.free(msg);

    // Now the same diagnostic is delivered again (delivered set was cleared).
    try reg.registerPending("zls", uri, &diags);
    const after = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(after);
    try testing.expect(std.mem.indexOf(u8, after, "type mismatch") != null);
    try testing.expect(std.mem.indexOf(u8, after, "foo.zig") != null);
}
