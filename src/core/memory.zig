const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");

/// Memory scope: global (user-level) or workspace (project-level)
pub const MemoryScope = enum {
    global,
    workspace,
};

/// A single memory entry loaded from disk.
pub const MemoryEntry = struct {
    name: []u8,
    category: []u8,
    content: []u8,
    path: []u8,
    scope: MemoryScope = .global,
    /// Nanoseconds since Unix epoch; captured from the file's mtime
    /// at load time so the render pass can prepend a freshness
    /// caveat to memories that are stale enough the model should
    /// verify them before quoting ("this memory is 47 days old...").
    /// Ported in spirit from claude-code-main/src/memdir/memoryAge.ts.
    mtime_ns: i128 = 0,

    pub fn deinit(self: *MemoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.category);
        allocator.free(self.content);
        allocator.free(self.path);
    }
};

/// Days elapsed since `mtime_ns`, floor-rounded relative to
/// `now_ns`. Negative deltas (clock skew, mtime in the future)
/// clamp to 0. Pure function so callers can inject a synthetic
/// `now_ns` in tests. Matches memoryAgeDays in the reference.
pub fn memoryAgeDays(mtime_ns: i128, now_ns: i128) u32 {
    const delta = now_ns - mtime_ns;
    if (delta <= 0) return 0;
    const ns_per_day: i128 = @as(i128, std.time.ns_per_s) * 24 * 60 * 60;
    const days = @divFloor(delta, ns_per_day);
    if (days > std.math.maxInt(u32)) return std.math.maxInt(u32);
    return @intCast(days);
}

/// Write a human-readable age string into `buf`. "today" for 0
/// days, "yesterday" for 1 day, "{n} days ago" for anything older.
/// Returns a slice of the buffer. Matches memoryAge in the reference.
pub fn memoryAgeString(buf: []u8, days: u32) []const u8 {
    if (days == 0) {
        const src = "today";
        const n = @min(buf.len, src.len);
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }
    if (days == 1) {
        const src = "yesterday";
        const n = @min(buf.len, src.len);
        @memcpy(buf[0..n], src[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{d} days ago", .{days}) catch "many days ago";
}

/// Freshness caveat text for memories strictly older than one day.
/// Ported from memoryFreshnessText: the motivation is that models
/// cite stale `file:line` references from old memories as if they
/// were current code, so an explicit "verify before asserting"
/// note tempers the confidence. Empty string for fresh entries.
/// Returns a slice of `buf`; caller must size the buffer for
/// the worst-case message (~256 bytes).
pub fn memoryFreshnessText(buf: []u8, days: u32) []const u8 {
    if (days <= 1) return "";
    return std.fmt.bufPrint(
        buf,
        "This memory is {d} days old. Memories are point-in-time observations, not live state -- claims about code behavior or file:line citations may be outdated. Verify against current code before asserting as fact.",
        .{days},
    ) catch "";
}

/// Load all memory entries from ~/.zcode/memory/*.md
pub fn loadAll(allocator: std.mem.Allocator) ![]MemoryEntry {
    return loadAllWithWorkspace(allocator, null);
}

/// Load memories from global (~/.zcode/memory) and optionally workspace (.zcode/memory)
pub fn loadAllWithWorkspace(allocator: std.mem.Allocator, workspace_cwd: ?[]const u8) ![]MemoryEntry {
    var entries = std.array_list.Managed(MemoryEntry).init(allocator);
    errdefer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }

    // Load global memories
    const global_dir = try memoryDirPath(allocator);
    defer allocator.free(global_dir);
    try loadFromDir(allocator, &entries, global_dir, .global);

    // Load workspace memories if a cwd was provided
    if (workspace_cwd) |cwd| {
        const ws_dir = try std.fs.path.join(allocator, &.{ cwd, ".zcode", "memory" });
        defer allocator.free(ws_dir);
        try loadFromDir(allocator, &entries, ws_dir, .workspace);
    }

    return entries.toOwnedSlice();
}

fn loadFromDir(
    allocator: std.mem.Allocator,
    entries: *std.array_list.Managed(MemoryEntry),
    dir_path: []const u8,
    scope: MemoryScope,
) !void {
    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.endsWith(u8, file.name, ".md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, file.name });
        defer allocator.free(full_path);

        const content = std.Io.Dir.cwd().readFileAlloc(rt.io, full_path, allocator, .limited(64 * 1024)) catch continue;
        defer allocator.free(content);

        var entry = parseMemoryFile(allocator, file.name, content) catch continue;
        errdefer {
            allocator.free(entry.name);
            allocator.free(entry.category);
            allocator.free(entry.content);
            allocator.free(entry.path);
        }
        // parseMemoryFile leaves entry.path as an empty dupe; replace it with the real path.
        allocator.free(entry.path);
        entry.path = try allocator.dupe(u8, full_path);
        entry.scope = scope;
        // Capture the file mtime so rendering can add a freshness
        // caveat for stale entries. A stat failure leaves mtime at
        // its default 0, which memoryAgeDays maps to a very large
        // number of days and therefore the caveat line fires --
        // that's a safe fallback since "unknown age" should be
        // treated as suspect rather than current.
        if (std.Io.Dir.cwd().statFile(rt.io, full_path, .{})) |stat| {
            entry.mtime_ns = stat.mtime.toNanoseconds();
        } else |_| {}

        try entries.append(entry);
    }
}

/// Render all memories as a single string for injection into the system prompt.
pub fn renderForPrompt(allocator: std.mem.Allocator, entries: []const MemoryEntry) ![]u8 {
    if (entries.len == 0) return allocator.dupe(u8, "");

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    try out.writer().writeAll("# Persistent Memory\n\n");
    try out.writer().writeAll("The following memories were saved from previous conversations.\n\n");

    for (entries) |entry| {
        try out.writer().print("## [{s}] {s}\n\n{s}\n\n", .{ entry.category, entry.name, entry.content });
    }

    return out.toOwnedSlice();
}

/// Returns true for categories whose entries must always be included
/// in every prompt regardless of relevance score. These are durable rules
/// the user has explicitly committed to, not episodic facts.
fn isAlwaysIncludeCategory(category: []const u8) bool {
    return std.ascii.eqlIgnoreCase(category, "rule") or
        std.ascii.eqlIgnoreCase(category, "rules") or
        std.ascii.eqlIgnoreCase(category, "feedback") or
        std.ascii.eqlIgnoreCase(category, "always");
}

pub fn renderRelevantForPrompt(allocator: std.mem.Allocator, entries: []const MemoryEntry, prompt: []const u8, max_items: usize) ![]u8 {
    if (entries.len == 0) return allocator.dupe(u8, "");

    const Ranked = struct {
        index: usize,
        score: usize,
    };

    var ranked = std.array_list.Managed(Ranked).init(allocator);
    defer ranked.deinit();
    var always_indices = std.array_list.Managed(usize).init(allocator);
    defer always_indices.deinit();

    for (entries, 0..) |entry, idx| {
        if (isAlwaysIncludeCategory(entry.category)) {
            try always_indices.append(idx);
            continue;
        }
        const score = scoreEntryForPrompt(entry, prompt);
        if (score == 0) continue;
        try ranked.append(.{ .index = idx, .score = score });
    }

    if (ranked.items.len == 0 and always_indices.items.len == 0) {
        return allocator.dupe(u8, "");
    }

    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            if (a.score == b.score) return a.index < b.index;
            return a.score > b.score;
        }
    }.lessThan);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    // Always-included rules come first with a strong header the model must obey.
    if (always_indices.items.len > 0) {
        try out.writer().writeAll("# ABSOLUTE RULES (MUST FOLLOW)\n\n");
        try out.writer().writeAll("These rules apply to EVERY response in this session. Violating them is a failure.\n\n");
        for (always_indices.items) |idx| {
            const entry = entries[idx];
            const scope_label = if (entry.scope == .workspace) "workspace" else "global";
            try out.writer().print("## [{s}/{s}] {s}\n\n{s}\n\n", .{ scope_label, entry.category, entry.name, entry.content });
        }
    }

    if (ranked.items.len > 0 and max_items > 0) {
        try out.writer().writeAll("# Relevant Persistent Memory\n\n");
        try out.writer().writeAll("Context memories relevant to the current request.\n\n");

        const now_ns: i128 = clock.nowNanos();
        const take = @min(max_items, ranked.items.len);
        for (ranked.items[0..take]) |item| {
            const entry = entries[item.index];
            const scope_label = if (entry.scope == .workspace) "workspace" else "global";
            var age_buf: [32]u8 = undefined;
            var fresh_buf: [320]u8 = undefined;
            const days = memoryAgeDays(entry.mtime_ns, now_ns);
            const age_str = memoryAgeString(&age_buf, days);
            try out.writer().print("## [{s}/{s}] {s} ({s})\n\n", .{ scope_label, entry.category, entry.name, age_str });
            const fresh = memoryFreshnessText(&fresh_buf, days);
            if (fresh.len > 0) {
                try out.writer().print("<system-reminder>{s}</system-reminder>\n\n", .{fresh});
            }
            try out.writer().print("{s}\n\n", .{entry.content});
        }
    }

    return out.toOwnedSlice();
}

// =====================================================================
// Frontmatter-only headers for the LLM relevance selector (memory-03).
//
// `findRelevantMemories` in the reference scans memory files reading only
// the first ~30 frontmatter lines (never the full body), sorts newest-first
// by mtime, caps at 200, excludes the MEMORY.md index, then formats a
// one-line-per-file manifest the model picks from. These two helpers are the
// scan + manifest stages; the side-query selection lives in
// memory_relevance.zig so the deterministic scorer above stays the offline
// default and is never replaced.
// =====================================================================

/// A frontmatter-only view of a memory file. Cheaper than MemoryEntry
/// (it never reads the body) and carries only what the manifest needs:
/// the filename, the `type`/`description` frontmatter fields, and the mtime
/// used to sort newest-first.
pub const MemoryHeader = struct {
    /// Bare filename (e.g. "writing-style.md"), owned.
    filename: []u8,
    /// `type` frontmatter value, owned. Empty when absent.
    mem_type: []u8,
    /// `description` frontmatter value, owned. Empty when absent.
    description: []u8,
    /// Nanoseconds since Unix epoch from the file mtime; 0 on stat failure.
    mtime_ns: i128 = 0,

    pub fn deinit(self: *MemoryHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.mem_type);
        allocator.free(self.description);
    }
};

/// Max files the scan returns (mirrors the reference's 200-file cap).
pub const MEMORY_SCAN_CAP: usize = 200;
/// Bytes read per file when scanning frontmatter. The reference reads the
/// first ~30 lines; a 4KB window comfortably covers a frontmatter block
/// plus slack without paying to read whole bodies.
const MEMORY_SCAN_READ_BYTES: usize = 4 * 1024;

/// Scan a memory directory for frontmatter-only headers, newest-first by
/// mtime, excluding `MEMORY.md`, capped at `max` (clamped to MEMORY_SCAN_CAP).
/// Returns an owned slice; caller frees each header then the slice. A missing
/// directory yields an empty slice (not an error) so offline/no-dir callers
/// degrade gracefully.
///
/// Ports scanMemoryFiles (claude-code-main/src/memdir/memoryScan.ts).
pub fn scanMemoryFiles(allocator: std.mem.Allocator, dir_path: []const u8, max: usize) ![]MemoryHeader {
    var headers = std.array_list.Managed(MemoryHeader).init(allocator);
    errdefer {
        for (headers.items) |*h| h.deinit(allocator);
        headers.deinit();
    }

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch {
        return headers.toOwnedSlice();
    };
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.endsWith(u8, file.name, ".md")) continue;
        // The index file is never a relevance candidate (always loaded).
        if (std.ascii.eqlIgnoreCase(file.name, "MEMORY.md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, file.name });
        defer allocator.free(full_path);

        // Read only the frontmatter window. StreamTooLong here would mean the
        // file is larger than our window, which is fine -- we only need the
        // head; a bounded read returns the prefix, so on the rare case the
        // read errors entirely we just skip the file.
        const head = std.Io.Dir.cwd().readFileAlloc(rt.io, full_path, allocator, .limited(MEMORY_SCAN_READ_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => blk: {
                // File exceeds the window: re-read exactly the window bytes so
                // the frontmatter (which lives at the top) is still parsed.
                break :blk std.Io.Dir.cwd().readFileAlloc(rt.io, full_path, allocator, .limited(MEMORY_SCAN_READ_BYTES + 1)) catch continue;
            },
            else => continue,
        };
        defer allocator.free(head);

        var mem_type: []const u8 = "";
        var description: []const u8 = "";
        if (frontmatter_mod.extract(head)) |block| {
            if (frontmatter_mod.getValue(block.body, "type")) |v| mem_type = v;
            if (frontmatter_mod.getValue(block.body, "description")) |v| description = v;
        }

        var mtime_ns: i128 = 0;
        if (std.Io.Dir.cwd().statFile(rt.io, full_path, .{})) |stat| {
            mtime_ns = stat.mtime.toNanoseconds();
        } else |_| {}

        try headers.append(.{
            .filename = try allocator.dupe(u8, file.name),
            .mem_type = try allocator.dupe(u8, mem_type),
            .description = try allocator.dupe(u8, description),
            .mtime_ns = mtime_ns,
        });
    }

    // Newest-first.
    std.mem.sort(MemoryHeader, headers.items, {}, struct {
        fn lessThan(_: void, a: MemoryHeader, b: MemoryHeader) bool {
            if (a.mtime_ns == b.mtime_ns) return std.mem.lessThan(u8, a.filename, b.filename);
            return a.mtime_ns > b.mtime_ns;
        }
    }.lessThan);

    // Cap (the smaller of the requested max and the hard scan cap).
    const cap = @min(max, MEMORY_SCAN_CAP);
    if (headers.items.len > cap) {
        for (headers.items[cap..]) |*h| h.deinit(allocator);
        headers.shrinkRetainingCapacity(cap);
    }

    return headers.toOwnedSlice();
}

/// Format a one-line-per-file manifest from scanned headers. Each line:
///   `- [type] filename (ISO-mtime): description`
/// The `[type]` prefix is omitted when type is empty; the `: description`
/// suffix is omitted when description is empty. The timestamp is ISO-8601
/// UTC (seconds precision). Caller owns the returned slice.
///
/// Ports formatMemoryManifest (claude-code-main/src/memdir/memoryScan.ts).
pub fn formatMemoryManifest(allocator: std.mem.Allocator, headers: []const MemoryHeader) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (headers) |h| {
        try out.writer().writeAll("- ");
        if (h.mem_type.len > 0) {
            try out.writer().print("[{s}] ", .{h.mem_type});
        }
        var ts_buf: [32]u8 = undefined;
        const ts = formatIsoUtc(&ts_buf, h.mtime_ns);
        try out.writer().print("{s} ({s})", .{ h.filename, ts });
        if (h.description.len > 0) {
            try out.writer().print(": {s}", .{h.description});
        }
        try out.writer().writeByte('\n');
    }

    return out.toOwnedSlice();
}

/// Format `mtime_ns` (nanoseconds since Unix epoch) as ISO-8601 UTC with
/// seconds precision: `YYYY-MM-DDTHH:MM:SSZ`. Returns a slice of `buf`.
/// Negative / zero timestamps render as the Unix epoch start. No general
/// date library exists in the tree; this is the minimal formatter the
/// manifest needs.
fn formatIsoUtc(buf: []u8, mtime_ns: i128) []const u8 {
    const secs_i: i128 = if (mtime_ns <= 0) 0 else @divFloor(mtime_ns, std.time.ns_per_s);
    const secs: u64 = if (secs_i < 0) 0 else @intCast(secs_i);
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u16, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch "1970-01-01T00:00:00Z";
}

/// Save a memory entry to disk.
pub fn save(allocator: std.mem.Allocator, name: []const u8, category: []const u8, content: []const u8) ![]u8 {
    const memory_dir = try memoryDirPath(allocator);
    defer allocator.free(memory_dir);
    try paths.ensureDir(memory_dir);

    // Sanitize name for filename.
    var filename_buf: [256]u8 = undefined;
    var filename_len: usize = 0;
    for (name) |ch| {
        if (filename_len >= 200) break;
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
            filename_buf[filename_len] = std.ascii.toLower(ch);
            filename_len += 1;
        } else if (ch == ' ') {
            filename_buf[filename_len] = '_';
            filename_len += 1;
        }
    }
    if (filename_len == 0) return error.InvalidMemoryName;

    const filename = try std.fmt.allocPrint(allocator, "{s}.md", .{filename_buf[0..filename_len]});
    defer allocator.free(filename);

    const full_path = try std.fs.path.join(allocator, &.{ memory_dir, filename });
    defer allocator.free(full_path);

    var file_content = std_io.StringBuilder.init(allocator);
    defer file_content.deinit();

    try file_content.writer().print("---\nname: {s}\ncategory: {s}\n---\n\n{s}\n", .{ name, category, content });

    // Atomic write so a SIGINT mid-save can't leave the memory entry
    // at 0 bytes (the loader would fail to parse the empty file or
    // skip it, silently losing whatever the user just tried to
    // persist). Same discipline as keychain.zig (pass 64),
    // logger.zig (pass 65), security.zig (pass 67), etc.
    try writeMemoryFileAtomic(allocator, full_path, file_content.items());

    return std.fmt.allocPrint(allocator, "saved memory: [{s}] {s} -> {s}", .{ category, name, filename });
}

fn writeMemoryFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("memory: chmod failed for tmp file: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

/// Delete a memory entry by name.
pub fn delete(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const entries = try loadAll(allocator);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    for (entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            std.Io.Dir.cwd().deleteFile(rt.io, entry.path) catch |err| {
                return std.fmt.allocPrint(allocator, "failed to delete memory: {s}", .{@errorName(err)});
            };
            return std.fmt.allocPrint(allocator, "deleted memory: {s}", .{entry.name});
        }
    }

    return std.fmt.allocPrint(allocator, "memory not found: {s}", .{name});
}

/// The section header that `appendUserMemory` writes user memory lines under.
/// Stable so repeated `#`-mode captures accumulate in one place rather than
/// scattering across the file.
pub const USER_MEMORY_SECTION = "## User Memories";

/// True when `prompt` is a `#`-prefix memory-capture input with a non-empty
/// remainder after the `#`. Mirrors the reference's leading-`#` input mode
/// (`PromptInput/inputModes.ts`). A bare `#` (or `#` followed by only
/// whitespace) is NOT a capture -- there is nothing to remember. This is the
/// extracted, unit-testable predicate behind the REPL submit-path routing.
pub fn isMemoryCapture(prompt: []const u8) bool {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len < 2) return false;
    if (trimmed[0] != '#') return false;
    const remainder = std.mem.trim(u8, trimmed[1..], " \t\r\n");
    return remainder.len > 0;
}

/// Strip the leading `#` (and surrounding whitespace) from a memory-capture
/// prompt, returning the bare memory line to persist. Slices into `prompt`.
/// Precondition: `isMemoryCapture(prompt)` is true.
pub fn memoryCaptureLine(prompt: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    return std.mem.trim(u8, trimmed[1..], " \t\r\n");
}

/// Resolve the project instruction file to append user memory to. Prefers an
/// existing `ZCODE.md` (the primary instruction filename), then an existing
/// `CLAUDE.md`; if neither exists, defaults to creating `CLAUDE.md` for
/// reference parity (the reference persists `#`-mode memory to the project
/// CLAUDE.md). `workspace` is the project-root cwd (the REPL's
/// `status_workspace`); when empty, resolves relative to the process cwd.
/// Caller owns the returned path.
pub fn projectMemoryFilePath(allocator: std.mem.Allocator, workspace: []const u8) ![]u8 {
    const root = if (workspace.len > 0) workspace else ".";
    const zcode_md = try std.fs.path.join(allocator, &.{ root, "ZCODE.md" });
    if (fileExistsAt(zcode_md)) return zcode_md;
    allocator.free(zcode_md);

    const claude_md = try std.fs.path.join(allocator, &.{ root, "CLAUDE.md" });
    return claude_md;
}

fn fileExistsAt(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return false;
    return true;
}

/// Append a user-captured memory `line` to the project instruction file under
/// the `USER_MEMORY_SECTION` header, creating the file (and the section) if
/// absent. `workspace` is the project-root cwd; pass the REPL's
/// `status_workspace`. The write is read-modify-atomic-write (the project
/// instruction file is small) so a SIGINT mid-write cannot truncate it.
///
/// The file is written world-readable (0o644) because it is an ordinary
/// project file that is often checked into VCS, unlike the 0o600 memory-dir
/// entries.
pub fn appendUserMemory(allocator: std.mem.Allocator, workspace: []const u8, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyMemoryLine;

    const file_path = try projectMemoryFilePath(allocator, workspace);
    defer allocator.free(file_path);

    // Read existing content (empty if the file does not exist yet).
    const existing: []u8 = std.Io.Dir.cwd().readFileAlloc(rt.io, file_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (existing.len == 0) {
        // Fresh file: start with the section header.
        try out.writer().print("{s}\n\n- {s}\n", .{ USER_MEMORY_SECTION, trimmed });
    } else {
        try out.writer().writeAll(existing);
        // Ensure a separating newline before we append.
        if (existing[existing.len - 1] != '\n') try out.writer().writeAll("\n");
        if (std.mem.indexOf(u8, existing, USER_MEMORY_SECTION) == null) {
            // No section yet: add one, with a blank line before it for spacing.
            try out.writer().print("\n{s}\n\n- {s}\n", .{ USER_MEMORY_SECTION, trimmed });
        } else {
            // Section exists: append the bullet at the end of the file. (We do
            // not splice into the middle of the section -- a trailing bullet
            // still reads naturally and keeps the writer simple.)
            try out.writer().print("- {s}\n", .{trimmed});
        }
    }

    try writeProjectFileAtomic(allocator, file_path, out.items());
}

/// Atomic write for the project instruction file: temp file + rename, with
/// 0o644 permissions (ordinary project file, not a secret). Mirrors
/// `writeMemoryFileAtomic` but without the restrictive 0o600 mode.
fn writeProjectFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o644) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    // Use cwd().rename rather than renameAbsolute: the target may be a relative
    // project path (workspace == "." or a relative status_workspace), which
    // renameAbsolute asserts against. cwd().rename handles both forms.
    const cwd_dir = std.Io.Dir.cwd();
    try cwd_dir.rename(tmp_path, cwd_dir, target, rt.io);
}

/// List all memory entries.
pub fn list(allocator: std.mem.Allocator) ![]u8 {
    return listWithWorkspace(allocator, null);
}

pub fn listWithWorkspace(allocator: std.mem.Allocator, workspace_cwd: ?[]const u8) ![]u8 {
    const entries = try loadAllWithWorkspace(allocator, workspace_cwd);
    defer {
        for (entries) |*e| {
            var entry = e.*;
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    if (entries.len == 0) {
        return allocator.dupe(u8, "no memories saved\n\nuse /memory save <category> <name> <content> to save a memory\ncategories: rule (always enforced), feedback (always enforced), user, project, reference\n\nmemory scopes:\n  global:    ~/.zcode/memory/*.md\n  workspace: ./.zcode/memory/*.md\n");
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print("memories ({d}):\n", .{entries.len});
    for (entries) |entry| {
        const preview_len = @min(entry.content.len, 80);
        const preview = entry.content[0..preview_len];
        const scope_label = if (entry.scope == .workspace) "workspace" else "global";
        try out.writer().print("  [{s}/{s}] {s} - {s}...\n", .{ scope_label, entry.category, entry.name, preview });
    }

    return out.toOwnedSlice();
}

// --- Internal helpers ---

fn memoryDirPath(allocator: std.mem.Allocator) ![]u8 {
    return memoryDirPathPub(allocator);
}

pub fn memoryDirPathPub(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "memory" });
}

fn parseMemoryFile(allocator: std.mem.Allocator, filename: []const u8, raw_content: []const u8) !MemoryEntry {
    var name: []const u8 = stripExtension(filename);
    var category: []const u8 = "general";
    var body = raw_content;

    if (frontmatter_mod.extract(raw_content)) |block| {
        body = block.rest;
        if (frontmatter_mod.getValue(block.body, "name")) |v| name = v;
        if (frontmatter_mod.getValue(block.body, "category")) |v| category = v;
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .category = try allocator.dupe(u8, category),
        .content = try allocator.dupe(u8, std.mem.trim(u8, body, " \t\r\n")),
        .path = try allocator.dupe(u8, ""), // Filled by caller.
    };
}

const frontmatter_mod = @import("frontmatter.zig");

fn stripExtension(filename: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot| return filename[0..dot];
    return filename;
}

fn scoreEntryForPrompt(entry: MemoryEntry, prompt: []const u8) usize {
    const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed_prompt.len == 0) return 0;

    var score: usize = 0;
    if (containsIgnoreCase(trimmed_prompt, entry.name)) score += 80;
    if (containsIgnoreCase(trimmed_prompt, entry.category)) score += 30;

    var name_tokens = std.mem.tokenizeAny(u8, entry.name, " \t\r\n-_/:");
    while (name_tokens.next()) |token| {
        if (token.len < 4) continue;
        if (containsIgnoreCase(trimmed_prompt, token)) score += 20;
    }

    var content_tokens = std.mem.tokenizeAny(u8, entry.content, " \t\r\n-_/:,.()[]{}");
    var content_matches: usize = 0;
    while (content_tokens.next()) |token| {
        if (token.len < 5) continue;
        if (containsIgnoreCase(trimmed_prompt, token)) {
            score += 10;
            content_matches += 1;
            if (content_matches >= 6) break;
        }
    }

    if (looksLikeCodePrompt(trimmed_prompt) and (eqlIgnoreCase(entry.category, "project") or eqlIgnoreCase(entry.category, "reference"))) {
        score += 10;
    }

    return score;
}

fn looksLikeCodePrompt(prompt: []const u8) bool {
    const cues = [_][]const u8{
        "code",      "repo",    "repository", "file",      "build",
        "test",      "debug",   "fix",        "implement", "refactor",
        "configure", "runtime", "agent",      "tool",      "prompt",
    };
    for (cues) |cue| {
        if (containsIgnoreCase(prompt, cue)) return true;
    }
    return false;
}

const containsIgnoreCase = @import("parse_helpers.zig").containsIgnoreCase;
const eqlIgnoreCase = @import("parse_helpers.zig").eqlIgnoreCase;

const testing = std.testing;

test "parseMemoryFile extracts frontmatter" {
    const raw = "---\nname: test preference\ncategory: feedback\n---\n\nAlways use tabs.";
    var entry = try parseMemoryFile(testing.allocator, "test.md", raw);
    defer entry.deinit(testing.allocator);

    try testing.expectEqualStrings("test preference", entry.name);
    try testing.expectEqualStrings("feedback", entry.category);
    try testing.expectEqualStrings("Always use tabs.", entry.content);
}

test "parseMemoryFile handles no frontmatter" {
    var entry = try parseMemoryFile(testing.allocator, "simple_note.md", "Just a plain note.");
    defer entry.deinit(testing.allocator);

    try testing.expectEqualStrings("simple_note", entry.name);
    try testing.expectEqualStrings("general", entry.category);
    try testing.expectEqualStrings("Just a plain note.", entry.content);
}

test "renderRelevantForPrompt keeps only matching memories" {
    const entries = try testing.allocator.alloc(MemoryEntry, 3);
    defer {
        for (entries) |*entry| entry.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    entries[0] = .{
        .name = try testing.allocator.dupe(u8, "zig runtime"),
        .category = try testing.allocator.dupe(u8, "project"),
        .content = try testing.allocator.dupe(u8, "AgentRuntime coordinates prompt building and tool execution."),
        .path = try testing.allocator.dupe(u8, "/tmp/runtime.md"),
    };
    entries[1] = .{
        .name = try testing.allocator.dupe(u8, "writing style"),
        .category = try testing.allocator.dupe(u8, "feedback"),
        .content = try testing.allocator.dupe(u8, "Keep final answers concise."),
        .path = try testing.allocator.dupe(u8, "/tmp/style.md"),
    };
    entries[2] = .{
        .name = try testing.allocator.dupe(u8, "travel notes"),
        .category = try testing.allocator.dupe(u8, "general"),
        .content = try testing.allocator.dupe(u8, "Remember the hotel address."),
        .path = try testing.allocator.dupe(u8, "/tmp/travel.md"),
    };

    const rendered = try renderRelevantForPrompt(testing.allocator, entries, "investigate the runtime tool execution loop", 2);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "zig runtime") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "travel notes") == null);
}

test "memoryAgeDays floors the delta and clamps negatives to zero" {
    const now: i128 = 1_700_000_000_000_000_000;
    const ns_per_day: i128 = @as(i128, std.time.ns_per_s) * 24 * 60 * 60;

    try testing.expectEqual(@as(u32, 0), memoryAgeDays(now, now));
    try testing.expectEqual(@as(u32, 1), memoryAgeDays(now - ns_per_day, now));
    try testing.expectEqual(@as(u32, 47), memoryAgeDays(now - 47 * ns_per_day, now));
    // Future mtime (clock skew): clamp to 0 rather than underflow.
    try testing.expectEqual(@as(u32, 0), memoryAgeDays(now + ns_per_day, now));
}

test "memoryAgeString picks today/yesterday/N days ago" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("today", memoryAgeString(&buf, 0));
    try testing.expectEqualStrings("yesterday", memoryAgeString(&buf, 1));
    try testing.expectEqualStrings("2 days ago", memoryAgeString(&buf, 2));
    try testing.expectEqualStrings("47 days ago", memoryAgeString(&buf, 47));
}

test "memoryFreshnessText stays empty for fresh memories" {
    var buf: [320]u8 = undefined;
    try testing.expectEqualStrings("", memoryFreshnessText(&buf, 0));
    try testing.expectEqualStrings("", memoryFreshnessText(&buf, 1));
}

test "memoryFreshnessText warns for older-than-1-day memories" {
    var buf: [320]u8 = undefined;
    const out = memoryFreshnessText(&buf, 47);
    try testing.expect(std.mem.indexOf(u8, out, "47 days old") != null);
    try testing.expect(std.mem.indexOf(u8, out, "point-in-time observations") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Verify against current code") != null);
}

const test_helpers = @import("test_helpers.zig");

// Write a memory file into `dir` (a tmp dir's std.fs.Dir) with the given
// frontmatter `type`/`description` and force its mtime so newest-first
// ordering is deterministic regardless of the filesystem's wall clock.
fn writeScanFixture(
    tmp: *std.testing.TmpDir,
    sub_path: []const u8,
    mem_type: []const u8,
    description: []const u8,
    mtime_secs: i96,
) !void {
    var fc = std_io.StringBuilder.init(testing.allocator);
    defer fc.deinit();
    try fc.writer().print("---\ntype: {s}\ndescription: {s}\n---\n\nbody\n", .{ mem_type, description });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = sub_path, .data = fc.items() });

    var file = try tmp.dir.openFile(rt.io, sub_path, .{ .mode = .read_write });
    defer file.close(rt.io);
    try file.setTimestamps(rt.io, .{
        .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(mtime_secs * std.time.ns_per_s) },
    });
}

test "scanMemoryFiles returns headers newest-first and excludes MEMORY.md" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // older.md (older mtime), newer.md (newer mtime), MEMORY.md (must be skipped).
    try writeScanFixture(&tmp, "older.md", "reference", "old note", 1_000);
    try writeScanFixture(&tmp, "newer.md", "feedback", "fresh note", 2_000);
    try writeScanFixture(&tmp, "MEMORY.md", "project", "the index", 3_000);

    const dir_abs = try test_helpers.tmpDirCwd(a, &tmp);
    defer a.free(dir_abs);

    const headers = try scanMemoryFiles(a, dir_abs, 200);
    defer {
        for (headers) |*h| h.deinit(a);
        a.free(headers);
    }

    try testing.expectEqual(@as(usize, 2), headers.len);
    // Newest first: newer.md before older.md.
    try testing.expectEqualStrings("newer.md", headers[0].filename);
    try testing.expectEqualStrings("older.md", headers[1].filename);
    try testing.expectEqualStrings("feedback", headers[0].mem_type);
    try testing.expectEqualStrings("fresh note", headers[0].description);
    // The index file was excluded.
    for (headers) |h| try testing.expect(!std.ascii.eqlIgnoreCase(h.filename, "MEMORY.md"));
}

test "scanMemoryFiles respects the requested cap" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeScanFixture(&tmp, "a.md", "user", "a", 1_000);
    try writeScanFixture(&tmp, "b.md", "user", "b", 2_000);
    try writeScanFixture(&tmp, "c.md", "user", "c", 3_000);

    const dir_abs = try test_helpers.tmpDirCwd(a, &tmp);
    defer a.free(dir_abs);

    const headers = try scanMemoryFiles(a, dir_abs, 2);
    defer {
        for (headers) |*h| h.deinit(a);
        a.free(headers);
    }

    try testing.expectEqual(@as(usize, 2), headers.len);
    // Cap keeps the newest two: c.md (3000) then b.md (2000).
    try testing.expectEqualStrings("c.md", headers[0].filename);
    try testing.expectEqualStrings("b.md", headers[1].filename);
}

test "scanMemoryFiles returns empty for a missing directory" {
    const a = testing.allocator;
    const headers = try scanMemoryFiles(a, "/nonexistent/zcode/memory/dir/xyz", 200);
    defer a.free(headers);
    try testing.expectEqual(@as(usize, 0), headers.len);
}

test "formatMemoryManifest emits typed and bare lines" {
    const a = testing.allocator;
    var headers = [_]MemoryHeader{
        .{
            .filename = try a.dupe(u8, "foo.md"),
            .mem_type = try a.dupe(u8, "feedback"),
            .description = try a.dupe(u8, "desc"),
            .mtime_ns = 1_700_000_000 * @as(i128, std.time.ns_per_s),
        },
        .{
            .filename = try a.dupe(u8, "bar.md"),
            .mem_type = try a.dupe(u8, ""),
            .description = try a.dupe(u8, ""),
            .mtime_ns = 1_700_000_000 * @as(i128, std.time.ns_per_s),
        },
    };
    defer for (&headers) |*h| h.deinit(a);

    const manifest = try formatMemoryManifest(a, &headers);
    defer a.free(manifest);

    // Typed/described line carries the [type] prefix, an ISO timestamp, and ": desc".
    try testing.expect(std.mem.indexOf(u8, manifest, "- [feedback] foo.md (") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "Z): desc") != null);
    // Bare line: no [type] prefix, no ": description" suffix.
    try testing.expect(std.mem.indexOf(u8, manifest, "- bar.md (") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "bar.md") != null);
    // The bare line must not gain a description colon-suffix.
    const bar_line_start = std.mem.indexOf(u8, manifest, "- bar.md (").?;
    const bar_line_end = std.mem.indexOfScalarPos(u8, manifest, bar_line_start, '\n') orelse manifest.len;
    const bar_line = manifest[bar_line_start..bar_line_end];
    try testing.expect(std.mem.endsWith(u8, bar_line, "Z)"));
}

test "formatIsoUtc renders a known epoch second" {
    var buf: [32]u8 = undefined;
    // 2023-11-14T22:13:20Z == 1700000000 unix seconds.
    const ts = formatIsoUtc(&buf, 1_700_000_000 * @as(i128, std.time.ns_per_s));
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", ts);
    // Epoch start / non-positive clamps to the Unix epoch.
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIsoUtc(&buf, 0));
}

test "isMemoryCapture detects leading-# input with a remainder" {
    try testing.expect(isMemoryCapture("# always run zig fmt before commit"));
    try testing.expect(isMemoryCapture("#no space needed"));
    try testing.expect(isMemoryCapture("   # leading whitespace then hash"));
    // No remainder -> not a capture.
    try testing.expect(!isMemoryCapture("#"));
    try testing.expect(!isMemoryCapture("#   "));
    try testing.expect(!isMemoryCapture("   #   "));
    // Not a leading hash.
    try testing.expect(!isMemoryCapture("hello # world"));
    try testing.expect(!isMemoryCapture("/memory save"));
    try testing.expect(!isMemoryCapture(""));
}

test "memoryCaptureLine strips the # and surrounding whitespace" {
    try testing.expectEqualStrings("always run zig fmt", memoryCaptureLine("# always run zig fmt"));
    try testing.expectEqualStrings("tight", memoryCaptureLine("#tight"));
    try testing.expectEqualStrings("padded", memoryCaptureLine("   #   padded   "));
}

test "appendUserMemory creates the project file and accumulates lines" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Real absolute path to the tmp dir (never pass "." per CLAUDE.md).
    const ws = try test_helpers.tmpDirCwd(a, &tmp);
    defer a.free(ws);

    // No instruction file exists yet -> defaults to creating CLAUDE.md.
    const path = try projectMemoryFilePath(a, ws);
    defer a.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "CLAUDE.md"));

    try appendUserMemory(a, ws, "always run zig fmt before commit");

    const after_first = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(1 << 20));
    defer a.free(after_first);
    try testing.expect(std.mem.indexOf(u8, after_first, USER_MEMORY_SECTION) != null);
    try testing.expect(std.mem.indexOf(u8, after_first, "- always run zig fmt before commit") != null);

    // Appending again keeps both lines under the same section.
    try appendUserMemory(a, ws, "prefer small diffs");

    const after_second = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(1 << 20));
    defer a.free(after_second);
    try testing.expect(std.mem.indexOf(u8, after_second, "- always run zig fmt before commit") != null);
    try testing.expect(std.mem.indexOf(u8, after_second, "- prefer small diffs") != null);
    // Only one section header (the second append reuses it).
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, after_second, idx, USER_MEMORY_SECTION)) |pos| {
        count += 1;
        idx = pos + USER_MEMORY_SECTION.len;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "appendUserMemory adds a section to an existing file without one" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Seed an existing ZCODE.md with prior content (no User Memories section).
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# Project Instructions\n\nUse Zig 0.16.\n" });

    const ws = try test_helpers.tmpDirCwd(a, &tmp);
    defer a.free(ws);

    // Existing ZCODE.md is preferred over CLAUDE.md.
    const path = try projectMemoryFilePath(a, ws);
    defer a.free(path);
    try testing.expect(std.mem.endsWith(u8, path, "ZCODE.md"));

    try appendUserMemory(a, ws, "remember the toolchain");

    const result = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(1 << 20));
    defer a.free(result);
    // Prior content preserved.
    try testing.expect(std.mem.indexOf(u8, result, "Use Zig 0.16.") != null);
    // New section + bullet appended.
    try testing.expect(std.mem.indexOf(u8, result, USER_MEMORY_SECTION) != null);
    try testing.expect(std.mem.indexOf(u8, result, "- remember the toolchain") != null);
}

test "appendUserMemory rejects an empty line" {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ws = try test_helpers.tmpDirCwd(a, &tmp);
    defer a.free(ws);
    try testing.expectError(error.EmptyMemoryLine, appendUserMemory(a, ws, "   "));
}
