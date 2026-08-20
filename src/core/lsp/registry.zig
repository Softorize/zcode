//! Passive-diagnostics registry (parity lsp-01).
//!
//! When a running language server emits a `textDocument/publishDiagnostics`
//! notification, the persistent server's reader thread parses it and calls
//! `registerPending` here. Each agent turn then calls `checkForDiagnostics`,
//! which drains the pending set and renders a compact
//! `<system-reminder name="lsp-diagnostics">` attachment that the turn loop
//! injects into the conversation -- so the model sees fresh compile/type errors
//! after an edit WITHOUT calling a tool. This is the headline LSP feature.
//!
//! Reference: `passiveFeedback.ts:125-328` (notification handler + format),
//! `passiveFeedback.ts:18-100` (`mapLSPSeverity` 1=Error..4=Hint), and the
//! per-turn consumption at `attachments.ts:959 getLSPDiagnosticAttachments`.
//!
//! Scope. This module covers two phase-19 slices on the same registry:
//!   - lsp-01: storage (`registerPending`), drain (`checkForDiagnostics`), and
//!     rendering (`formatForAttachment`) so the headline injection works.
//!   - lsp-03: within-batch dedup, cross-turn dedup via a bounded `delivered`
//!     LRU (uri -> set of content-keys), severity sort, per-file (10) and total
//!     (30) volume caps, and `clearDeliveredForFile` (re-edit re-shows).
//! Reference for lsp-03: `LSPDiagnosticRegistry.ts:42-43` (caps),
//! `:136-184 deduplicateDiagnosticFiles`, `:256-312 checkForLSPDiagnostics`,
//! `:372-379 clearDeliveredDiagnosticsForFile`.
//!
//! Concurrency. The reader thread writes (`registerPending`) while the turn loop
//! reads (`checkForDiagnostics`), so all state is guarded by an `std.Io.Mutex`
//! (it is shared singleton state, mirroring the reference's module-level maps).
//! Every stored string is owned by the registry allocator and freed on
//! overwrite / drain / reset (the parse arena is freed before return, so URIs
//! and messages are duped in -- the documented "value copy desyncs" footgun).

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../std_io.zig");

/// Volume + LRU caps (parity `LSPDiagnosticRegistry.ts:42-43`). A file is capped
/// to 10 diagnostics in one delivery, a single delivery to 30 across all files,
/// and the cross-turn `delivered` LRU to 500 tracked files (oldest evicted).
pub const MAX_DIAGNOSTICS_PER_FILE: usize = 10;
pub const MAX_TOTAL_DIAGNOSTICS: usize = 30;
pub const MAX_DELIVERED_FILES: usize = 500;

/// LSP diagnostic severity, mapped from the wire values (1..4). The reference's
/// `mapLSPSeverity` defaults an out-of-range / missing severity to Error.
pub const Severity = enum(u8) {
    error_ = 1,
    warning = 2,
    info = 3,
    hint = 4,

    /// Map a raw LSP severity integer to the enum, defaulting to Error for
    /// anything outside 1..4 (matches `mapLSPSeverity`).
    pub fn fromLsp(raw: i64) Severity {
        return switch (raw) {
            1 => .error_,
            2 => .warning,
            3 => .info,
            4 => .hint,
            else => .error_,
        };
    }

    /// Capitalized label used in the rendered attachment, matching the
    /// reference's "Error"/"Warning"/"Info"/"Hint".
    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .error_ => "Error",
            .warning => "Warning",
            .info => "Info",
            .hint => "Hint",
        };
    }

    /// Sort rank: Error first (lowest), Hint last. Mirrors the reference's
    /// severity-ascending order (Error=1..Hint=4).
    pub fn rank(self: Severity) u8 {
        return @intFromEnum(self);
    }
};

/// One diagnostic, reduced to the fields the attachment renders. `line`/`col`
/// are 0-based LSP positions; rendering converts to 1-based for display.
/// `source` and `code` are optional and rendered as a `[source/code]` suffix.
/// All strings are owned by the registry once stored.
pub const Diagnostic = struct {
    message: []const u8,
    severity: Severity,
    line: u32,
    col: u32,
    end_line: u32,
    end_col: u32,
    source: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

/// One file's pending diagnostics, keyed by URI. The latest publish for a URI
/// replaces the previous one (a server re-publishes the settled set per file).
const PendingEntry = struct {
    uri: []const u8,
    diags: []Diagnostic,
};

/// Cross-turn dedup record for one URI: the set of content-keys already
/// delivered (so an unchanged diagnostic is not re-shown next turn) plus an
/// insertion sequence used for LRU eviction once `MAX_DELIVERED_FILES` is hit.
/// Every key string is owned by the registry allocator.
const DeliveredEntry = struct {
    keys: std.StringHashMapUnmanaged(void) = .{},
    seq: u64,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// Pending (un-delivered) diagnostics, one entry per URI. Guarded by `mutex`.
    pending: std.ArrayListUnmanaged(PendingEntry) = .empty,
    /// Cross-turn delivered tracking: uri -> set of content-keys already shown.
    /// Bounded to `MAX_DELIVERED_FILES`; the oldest (lowest `seq`) URI is evicted
    /// on overflow. Keys (URIs) are owned by the registry allocator.
    delivered: std.StringHashMapUnmanaged(DeliveredEntry) = .{},
    /// Monotonic counter stamped on each delivered entry for LRU ordering.
    delivered_seq: u64 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Registry) void {
        self.lock();
        defer self.unlock();
        for (self.pending.items) |*e| self.freeEntry(e);
        self.pending.deinit(self.allocator);
        self.freeDeliveredLocked();
    }

    /// Record (or replace) the pending diagnostics for `uri`. An EMPTY `diags`
    /// means "this file is now clean": any pending entry for that URI is dropped
    /// and nothing is stored (reference `passiveFeedback.ts:196-205`). `server`
    /// is accepted for parity with the reference handler signature; lsp-01 does
    /// not key on it (one server per extension), but lsp-03 may. The registry
    /// dupes every string, so the caller may free its inputs after the call.
    pub fn registerPending(
        self: *Registry,
        server: []const u8,
        uri: []const u8,
        diags: []const Diagnostic,
    ) !void {
        _ = server;
        self.lock();
        defer self.unlock();

        // Drop any prior pending entry for this URI (latest publish wins, and an
        // empty publish clears it entirely).
        self.removeUriLocked(uri);
        if (diags.len == 0) return;

        const owned = try self.dupeDiags(diags);
        errdefer self.freeDiags(owned);
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        try self.pending.append(self.allocator, .{ .uri = owned_uri, .diags = owned });
    }

    /// Drain all pending diagnostics, apply within-batch + cross-turn dedup,
    /// severity sort, per-file and total volume caps, then render the survivors
    /// into a single `<system-reminder name="lsp-diagnostics">` attachment owned
    /// by `allocator`. Returns null when nothing pending OR nothing survives
    /// dedup/caps. After this call the pending set is empty and every surviving
    /// content-key is recorded in `delivered[uri]` so the identical diagnostic is
    /// suppressed next turn until the file is edited (`clearDeliveredForFile`).
    pub fn checkForDiagnostics(self: *Registry, allocator: std.mem.Allocator) !?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.pending.items.len == 0) return null;
        defer {
            // Drained regardless of what survived: the pending set is consumed.
            for (self.pending.items) |*e| self.freeEntry(e);
            self.pending.clearRetainingCapacity();
        }
        return try self.collectAndRenderLocked(allocator);
    }

    /// The lsp-03 filter pipeline. Caller holds the lock. For each pending file,
    /// in severity-ascending order, drop diagnostics whose content-key was
    /// already delivered for that URI (cross-turn dedup) or already seen earlier
    /// in this same batch for that URI (within-batch dedup), cap each file to
    /// `MAX_DIAGNOSTICS_PER_FILE`, and cap the running total across files to
    /// `MAX_TOTAL_DIAGNOSTICS`. Files with no survivors are skipped. Surviving
    /// keys are recorded into the `delivered` LRU. Returns the rendered
    /// attachment, or null when nothing survives.
    fn collectAndRenderLocked(self: *Registry, allocator: std.mem.Allocator) !?[]u8 {
        var buf = std_io.StringBuilder.init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        // Scratch arena for the per-batch content-key strings used only for the
        // within-batch dedup decision; the keys that survive are re-duped into
        // the registry allocator via `recordDeliveredLocked`.
        var key_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer key_arena.deinit();
        const ka = key_arena.allocator();

        var total: usize = 0;
        var wrote_any = false;

        for (self.pending.items) |entry| {
            if (total >= MAX_TOTAL_DIAGNOSTICS) break;
            // Stable, severity-ascending order so Errors survive the per-file cap
            // before Hints and render first.
            std.sort.block(Diagnostic, entry.diags, {}, severityLess);

            const path = uriToPath(entry.uri);
            const existing: ?*DeliveredEntry = self.delivered.getPtr(entry.uri);

            // Within-batch seen-set (content-keys) for this URI only.
            var seen: std.StringHashMapUnmanaged(void) = .{};
            // Survivor keys to record into `delivered[uri]` after rendering.
            var survivors: std.ArrayListUnmanaged([]const u8) = .empty;
            var per_file: usize = 0;

            for (entry.diags) |d| {
                if (per_file >= MAX_DIAGNOSTICS_PER_FILE) break;
                if (total >= MAX_TOTAL_DIAGNOSTICS) break;

                const key = try contentKey(ka, d);
                // Cross-turn dedup: already delivered for this URI.
                if (existing) |e| {
                    if (e.keys.contains(key)) continue;
                }
                // Within-batch dedup: duplicate inside this same publish.
                if (seen.contains(key)) continue;
                try seen.put(ka, key, {});

                try w.print("{s} {s}:{d}:{d}: {s}", .{
                    d.severity.label(),
                    path,
                    d.line + 1,
                    d.col + 1,
                    d.message,
                });
                if (d.source != null or d.code != null) {
                    try w.writeAll(" [");
                    if (d.source) |s| try w.writeAll(s);
                    if (d.code) |c| {
                        if (d.source != null) try w.writeAll("/");
                        try w.writeAll(c);
                    }
                    try w.writeAll("]");
                }
                try w.writeAll("\n");

                try survivors.append(ka, key);
                per_file += 1;
                total += 1;
                wrote_any = true;
            }

            if (survivors.items.len > 0) {
                try self.recordDeliveredLocked(entry.uri, survivors.items);
            }
        }

        if (!wrote_any) return null;

        // Prepend the reminder envelope once we know there is content.
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        const ow = out.writer();
        try ow.writeAll("<system-reminder name=\"lsp-diagnostics\">\n");
        try ow.writeAll("New diagnostics from language servers (no tool call needed):\n");
        try ow.writeAll(buf.items());
        try ow.writeAll("</system-reminder>");
        return try out.toOwnedSlice();
    }

    /// Record `keys` (within-batch arena-owned strings) into `delivered[uri]`,
    /// duping each key + the URI into the registry allocator. Creates the URI's
    /// entry (stamped with the next LRU seq) on first sight; evicts the oldest
    /// entry first if the map would exceed `MAX_DELIVERED_FILES`. Caller holds
    /// the lock.
    fn recordDeliveredLocked(self: *Registry, uri: []const u8, keys: []const []const u8) !void {
        const gop = try self.deliveredGetOrPutLocked(uri);
        for (keys) |k| {
            if (gop.keys.contains(k)) continue;
            const owned = try self.allocator.dupe(u8, k);
            errdefer self.allocator.free(owned);
            try gop.keys.put(self.allocator, owned, {});
        }
    }

    /// Get-or-create the `delivered` entry for `uri`, evicting the LRU-oldest URI
    /// first if inserting a new entry would exceed `MAX_DELIVERED_FILES`. Caller
    /// holds the lock.
    fn deliveredGetOrPutLocked(self: *Registry, uri: []const u8) !*DeliveredEntry {
        if (self.delivered.getPtr(uri)) |e| return e;

        if (self.delivered.count() >= MAX_DELIVERED_FILES) self.evictOldestDeliveredLocked();

        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        self.delivered_seq += 1;
        try self.delivered.put(self.allocator, owned_uri, .{ .seq = self.delivered_seq });
        return self.delivered.getPtr(owned_uri).?;
    }

    /// Remove the lowest-seq (oldest) entry from `delivered`, freeing its URI key
    /// and all its content-keys. Caller holds the lock.
    fn evictOldestDeliveredLocked(self: *Registry) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_seq: u64 = std.math.maxInt(u64);
        var it = self.delivered.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.seq < oldest_seq) {
                oldest_seq = kv.value_ptr.seq;
                oldest_key = kv.key_ptr.*;
            }
        }
        if (oldest_key) |ok| {
            if (self.delivered.fetchRemove(ok)) |removed| {
                var ent = removed.value;
                self.freeDeliveredEntry(&ent);
                self.allocator.free(removed.key);
            }
        }
    }

    /// Public formatting entry point (lock-acquiring) for callers that want the
    /// rendered text without draining -- currently only the unit tests use it;
    /// the turn loop uses `checkForDiagnostics`. Does NOT apply cross-turn dedup
    /// or caps (it is a raw view of the pending set).
    pub fn formatForAttachment(self: *Registry, allocator: std.mem.Allocator) !?[]u8 {
        self.lock();
        defer self.unlock();
        if (self.pending.items.len == 0) return null;

        var buf = std_io.StringBuilder.init(allocator);
        defer buf.deinit();
        const w = buf.writer();
        try w.writeAll("<system-reminder name=\"lsp-diagnostics\">\n");
        try w.writeAll("New diagnostics from language servers (no tool call needed):\n");
        for (self.pending.items) |entry| {
            const path = uriToPath(entry.uri);
            std.sort.block(Diagnostic, entry.diags, {}, severityLess);
            for (entry.diags) |d| {
                try w.print("{s} {s}:{d}:{d}: {s}", .{ d.severity.label(), path, d.line + 1, d.col + 1, d.message });
                if (d.source != null or d.code != null) {
                    try w.writeAll(" [");
                    if (d.source) |s| try w.writeAll(s);
                    if (d.code) |c| {
                        if (d.source != null) try w.writeAll("/");
                        try w.writeAll(c);
                    }
                    try w.writeAll("]");
                }
                try w.writeAll("\n");
            }
        }
        try w.writeAll("</system-reminder>");
        return try buf.toOwnedSlice();
    }

    /// Remove the cross-turn delivered tracking for `uri` so a re-edit re-shows
    /// diagnostics that were previously delivered (parity
    /// `LSPDiagnosticRegistry.ts:372-379 clearDeliveredDiagnosticsForFile`).
    /// No-op when the URI was never delivered.
    pub fn clearDeliveredForFile(self: *Registry, uri: []const u8) void {
        self.lock();
        defer self.unlock();
        if (self.delivered.fetchRemove(uri)) |removed| {
            var ent = removed.value;
            self.freeDeliveredEntry(&ent);
            self.allocator.free(removed.key);
        }
    }

    /// Clear every pending entry AND the cross-turn delivered map (session reset).
    pub fn resetAll(self: *Registry) void {
        self.lock();
        defer self.unlock();
        for (self.pending.items) |*e| self.freeEntry(e);
        self.pending.clearRetainingCapacity();
        self.freeDeliveredLocked();
        self.delivered = .{};
        self.delivered_seq = 0;
    }

    /// Free every delivered entry (URI key + content-key set) and the map's own
    /// backing storage. Caller holds the lock.
    fn freeDeliveredLocked(self: *Registry) void {
        var it = self.delivered.iterator();
        while (it.next()) |kv| {
            self.freeDeliveredEntry(kv.value_ptr);
            self.allocator.free(kv.key_ptr.*);
        }
        self.delivered.deinit(self.allocator);
    }

    /// Free one delivered entry's content-key set (and the key strings).
    fn freeDeliveredEntry(self: *Registry, ent: *DeliveredEntry) void {
        var kit = ent.keys.iterator();
        while (kit.next()) |kkv| self.allocator.free(kkv.key_ptr.*);
        ent.keys.deinit(self.allocator);
    }

    /// Remove (and free) any pending entry for `uri`. Caller holds the lock.
    fn removeUriLocked(self: *Registry, uri: []const u8) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (std.mem.eql(u8, self.pending.items[i].uri, uri)) {
                var e = self.pending.items[i];
                self.freeEntry(&e);
                _ = self.pending.swapRemove(i);
                continue; // do not advance: swapRemove moved a new item into i
            }
            i += 1;
        }
    }

    fn dupeDiags(self: *Registry, diags: []const Diagnostic) ![]Diagnostic {
        const out = try self.allocator.alloc(Diagnostic, diags.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |*d| self.freeDiag(d);
            self.allocator.free(out);
        }
        for (diags, 0..) |d, i| {
            const msg = try self.allocator.dupe(u8, d.message);
            errdefer self.allocator.free(msg);
            const src: ?[]const u8 = if (d.source) |s| try self.allocator.dupe(u8, s) else null;
            errdefer if (src) |s| self.allocator.free(s);
            const code: ?[]const u8 = if (d.code) |c| try self.allocator.dupe(u8, c) else null;
            out[i] = .{
                .message = msg,
                .severity = d.severity,
                .line = d.line,
                .col = d.col,
                .end_line = d.end_line,
                .end_col = d.end_col,
                .source = src,
                .code = code,
            };
            filled = i + 1;
        }
        return out;
    }

    fn freeEntry(self: *Registry, e: *PendingEntry) void {
        self.allocator.free(e.uri);
        self.freeDiags(e.diags);
    }

    fn freeDiags(self: *Registry, diags: []Diagnostic) void {
        for (diags) |*d| self.freeDiag(d);
        self.allocator.free(diags);
    }

    fn freeDiag(self: *Registry, d: *Diagnostic) void {
        self.allocator.free(d.message);
        if (d.source) |s| self.allocator.free(s);
        if (d.code) |c| self.allocator.free(c);
    }

    fn lock(self: *Registry) void {
        self.mutex.lock(self.io) catch {};
    }
    fn unlock(self: *Registry) void {
        self.mutex.unlock(self.io);
    }
};

fn severityLess(_: void, a: Diagnostic, b: Diagnostic) bool {
    return a.severity.rank() < b.severity.rank();
}

/// Stable content-key for one diagnostic, used for both within-batch and
/// cross-turn dedup. The reference (`LSPDiagnosticRegistry.ts:136-184`) keys on
/// `{message, severity, range, source, code}` via JSON stringify; a deterministic
/// pipe-delimited concatenation is equivalent and cheaper. Allocated with the
/// caller's allocator (a per-batch arena in `checkForDiagnostics`).
fn contentKey(allocator: std.mem.Allocator, d: Diagnostic) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}|{d}|{d}:{d}-{d}:{d}|{s}|{s}", .{
        d.message,
        @intFromEnum(d.severity),
        d.line,
        d.col,
        d.end_line,
        d.end_col,
        d.source orelse "",
        d.code orelse "",
    });
}

// --- Transitional process-global singleton ---------------------------------
//
// The reader threads (inside ServerInstance) write the registry and the agent
// turn loop reads it. Both reach the same registry through this singleton,
// mirroring how the LSP manager (core/lsp/manager.zig) and the runtime
// (core/runtime.zig) expose transitional process-globals. Null when no manager
// is installed (headless / --bare), in which case the turn loop's injection is
// a no-op and nothing is captured.

var instance: ?*Registry = null;

/// The installed registry, or null when none is installed. The turn loop guards
/// with `if (registry.get()) |reg| ...`.
pub fn get() ?*Registry {
    return instance;
}

/// Install a registry as the process singleton (called from agent runtime setup
/// alongside the LSP manager install).
pub fn install(reg: *Registry) void {
    instance = reg;
}

/// Uninstall the singleton (does not deinit the registry).
pub fn uninstall() void {
    instance = null;
}

/// Convert a `file://` URI to a plain path for display. A non-`file://` URI is
/// rendered verbatim. The diagnostic publish and the edit hooks must agree on
/// the URI form (reference normalizes via `pathToFileURL`); here we only strip
/// the scheme for the human-facing attachment.
pub fn uriToPath(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) return uri[prefix.len..];
    return uri;
}

/// Parse the params object of a `textDocument/publishDiagnostics` notification
/// into a URI + owned diagnostics. `body` is the framing-stripped JSON message
/// (the whole notification, not just params). Returns null when the params are
/// malformed / missing `uri` (the reference rejects these and the reader drops
/// them rather than crashing). An empty `diagnostics` array yields a valid
/// (uri, empty-slice) result -- the "this file is clean" signal.
///
/// The caller owns the returned URI and each diagnostic message/source/code and
/// must free them (or hand them straight to `registerPending`, which dupes and
/// then the caller frees). Exposed as a plain function so a unit test can drive
/// the dispatch path with a hand-built params JSON, decoupled from thread timing.
pub const Parsed = struct {
    uri: []const u8,
    diags: []Diagnostic,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        for (self.diags) |*d| {
            allocator.free(d.message);
            if (d.source) |s| allocator.free(s);
            if (d.code) |c| allocator.free(c);
        }
        allocator.free(self.diags);
    }
};

pub fn parsePublishDiagnostics(allocator: std.mem.Allocator, body: []const u8) !?Parsed {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const params = parsed.value.object.get("params") orelse return null;
    if (params != .object) return null;
    const pobj = params.object;

    const uri_v = pobj.get("uri") orelse return null;
    if (uri_v != .string) return null;
    const owned_uri = try allocator.dupe(u8, uri_v.string);
    errdefer allocator.free(owned_uri);

    var list: std.ArrayListUnmanaged(Diagnostic) = .empty;
    errdefer {
        for (list.items) |*d| {
            allocator.free(d.message);
            if (d.source) |s| allocator.free(s);
            if (d.code) |c| allocator.free(c);
        }
        list.deinit(allocator);
    }

    if (pobj.get("diagnostics")) |dv| {
        if (dv != .array) return null;
        for (dv.array.items) |item| {
            if (item != .object) continue;
            const d = try diagnosticFromValue(allocator, item.object);
            try list.append(allocator, d);
        }
    }

    return Parsed{ .uri = owned_uri, .diags = try list.toOwnedSlice(allocator) };
}

fn diagnosticFromValue(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Diagnostic {
    var line: u32 = 0;
    var col: u32 = 0;
    var end_line: u32 = 0;
    var end_col: u32 = 0;
    if (obj.get("range")) |range| {
        if (range == .object) {
            if (range.object.get("start")) |s| {
                if (s == .object) {
                    line = posField(s.object, "line");
                    col = posField(s.object, "character");
                }
            }
            if (range.object.get("end")) |e| {
                if (e == .object) {
                    end_line = posField(e.object, "line");
                    end_col = posField(e.object, "character");
                }
            }
        }
    }

    var severity: Severity = .error_;
    if (obj.get("severity")) |sv| {
        if (sv == .integer) severity = Severity.fromLsp(sv.integer);
    }

    const message = blk: {
        if (obj.get("message")) |mv| {
            if (mv == .string) break :blk try allocator.dupe(u8, mv.string);
        }
        break :blk try allocator.dupe(u8, "");
    };
    errdefer allocator.free(message);

    const source: ?[]const u8 = blk: {
        if (obj.get("source")) |sv| {
            if (sv == .string and sv.string.len > 0) break :blk try allocator.dupe(u8, sv.string);
        }
        break :blk null;
    };
    errdefer if (source) |s| allocator.free(s);

    // `code` may be a string or an integer in the LSP spec; render either.
    const code: ?[]const u8 = blk: {
        if (obj.get("code")) |cv| {
            switch (cv) {
                .string => |s| if (s.len > 0) break :blk try allocator.dupe(u8, s),
                .integer => |n| break :blk try std.fmt.allocPrint(allocator, "{d}", .{n}),
                else => {},
            }
        }
        break :blk null;
    };

    return .{
        .message = message,
        .severity = severity,
        .line = line,
        .col = col,
        .end_line = end_line,
        .end_col = end_col,
        .source = source,
        .code = code,
    };
}

fn posField(obj: std.json.ObjectMap, key: []const u8) u32 {
    if (obj.get(key)) |v| {
        if (v == .integer and v.integer >= 0) return @intCast(v.integer);
    }
    return 0;
}

// --- Tests ---

const testing = std.testing;

test "Severity.fromLsp maps 1..4 and defaults to Error" {
    try testing.expectEqual(Severity.error_, Severity.fromLsp(1));
    try testing.expectEqual(Severity.warning, Severity.fromLsp(2));
    try testing.expectEqual(Severity.info, Severity.fromLsp(3));
    try testing.expectEqual(Severity.hint, Severity.fromLsp(4));
    try testing.expectEqual(Severity.error_, Severity.fromLsp(0));
    try testing.expectEqual(Severity.error_, Severity.fromLsp(99));
}

test "registerPending then checkForDiagnostics renders an attachment naming the file and message" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const diags = [_]Diagnostic{
        .{ .message = "expected ';'", .severity = .error_, .line = 4, .col = 2, .end_line = 4, .end_col = 9 },
    };
    try reg.registerPending("zls", "file:///proj/foo.zig", &diags);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "lsp-diagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Error") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/proj/foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "expected ';'") != null);
    // 0-based 4:2 renders 1-based as 5:3.
    try testing.expect(std.mem.indexOf(u8, out, ":5:3:") != null);

    // Drained: a second check has nothing pending.
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}

test "empty publishDiagnostics clears pending for a uri and checkForDiagnostics returns empty" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const diags = [_]Diagnostic{
        .{ .message = "bad", .severity = .error_, .line = 0, .col = 0, .end_line = 0, .end_col = 1 },
    };
    try reg.registerPending("zls", "file:///clean.zig", &diags);
    // An empty publish (the "file is now clean" signal) drops the pending set.
    try reg.registerPending("zls", "file:///clean.zig", &.{});

    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}

test "diagnostics render Error-first regardless of registration order" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const diags = [_]Diagnostic{
        .{ .message = "a hint", .severity = .hint, .line = 1, .col = 0, .end_line = 1, .end_col = 1 },
        .{ .message = "a warning", .severity = .warning, .line = 2, .col = 0, .end_line = 2, .end_col = 1 },
        .{ .message = "an error", .severity = .error_, .line = 3, .col = 0, .end_line = 3, .end_col = 1 },
    };
    try reg.registerPending("zls", "file:///mix.zig", &diags);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);

    const err_idx = std.mem.indexOf(u8, out, "an error").?;
    const warn_idx = std.mem.indexOf(u8, out, "a warning").?;
    const hint_idx = std.mem.indexOf(u8, out, "a hint").?;
    try testing.expect(err_idx < warn_idx);
    try testing.expect(warn_idx < hint_idx);
}

test "source and code render as a bracketed suffix" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const diags = [_]Diagnostic{
        .{ .message = "unused", .severity = .warning, .line = 0, .col = 0, .end_line = 0, .end_col = 1, .source = "zls", .code = "unused_var" },
    };
    try reg.registerPending("zls", "file:///s.zig", &diags);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[zls/unused_var]") != null);
}

test "parsePublishDiagnostics extracts uri + diagnostics, registers and renders end to end" {
    rt.installForTest();
    const body =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///proj/foo.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":9}},\"severity\":1,\"message\":\"expected ';'\",\"source\":\"zls\",\"code\":42}" ++
        "]}}";

    var parsed = (try parsePublishDiagnostics(testing.allocator, body)).?;
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("file:///proj/foo.zig", parsed.uri);
    try testing.expectEqual(@as(usize, 1), parsed.diags.len);
    try testing.expectEqual(Severity.error_, parsed.diags[0].severity);
    try testing.expectEqualStrings("expected ';'", parsed.diags[0].message);
    try testing.expectEqualStrings("zls", parsed.diags[0].source.?);
    try testing.expectEqualStrings("42", parsed.diags[0].code.?);

    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();
    try reg.registerPending("zls", parsed.uri, parsed.diags);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "/proj/foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "expected ';'") != null);
}

test "parsePublishDiagnostics rejects malformed / missing uri" {
    rt.installForTest();
    try testing.expect((try parsePublishDiagnostics(testing.allocator, "not json")) == null);
    try testing.expect((try parsePublishDiagnostics(testing.allocator, "{\"params\":{}}")) == null);

    // Empty diagnostics array is a valid "clean file" result, not a rejection.
    var parsed = (try parsePublishDiagnostics(
        testing.allocator,
        "{\"params\":{\"uri\":\"file:///c.zig\",\"diagnostics\":[]}}",
    )).?;
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), parsed.diags.len);
}

test "uriToPath strips the file scheme" {
    try testing.expectEqualStrings("/a/b.zig", uriToPath("file:///a/b.zig"));
    try testing.expectEqualStrings("untitled:foo", uriToPath("untitled:foo"));
}

// --- lsp-03: dedup, volume caps, cross-turn tracking ---

test "lsp-03 within-batch dedup: the same diagnostic twice in one batch renders once" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const dup = Diagnostic{ .message = "dup err", .severity = .error_, .line = 1, .col = 1, .end_line = 1, .end_col = 5 };
    const diags = [_]Diagnostic{ dup, dup };
    try reg.registerPending("zls", "file:///d.zig", &diags);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);
    // Exactly one occurrence of the message survives the within-batch dedup.
    const first = std.mem.indexOf(u8, out, "dup err").?;
    try testing.expect(std.mem.indexOf(u8, out[first + 1 ..], "dup err") == null);
}

test "lsp-03 cross-turn dedup: an identical diagnostic next turn is suppressed" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const d = Diagnostic{ .message = "same", .severity = .error_, .line = 0, .col = 0, .end_line = 0, .end_col = 3 };
    const diags = [_]Diagnostic{d};

    // Turn 1: delivered.
    try reg.registerPending("zls", "file:///x.zig", &diags);
    const out1 = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out1);
    try testing.expect(std.mem.indexOf(u8, out1, "same") != null);

    // Turn 2: the server re-publishes the identical diagnostic -> suppressed.
    try reg.registerPending("zls", "file:///x.zig", &diags);
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}

test "lsp-03 clearDeliveredForFile re-shows a previously-delivered diagnostic" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const d = Diagnostic{ .message = "again", .severity = .error_, .line = 2, .col = 0, .end_line = 2, .end_col = 4 };
    const diags = [_]Diagnostic{d};

    try reg.registerPending("zls", "file:///y.zig", &diags);
    const out1 = (try reg.checkForDiagnostics(testing.allocator)).?;
    testing.allocator.free(out1);

    // The file was edited: clear its delivered tracking so a re-publish re-shows.
    reg.clearDeliveredForFile("file:///y.zig");

    try reg.registerPending("zls", "file:///y.zig", &diags);
    const out2 = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "again") != null);
}

test "lsp-03 per-file cap: 15 errors in one file are capped to 10" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    var diags: [15]Diagnostic = undefined;
    var msgs: [15][]u8 = undefined;
    for (0..15) |i| {
        msgs[i] = try std.fmt.allocPrint(testing.allocator, "err{d}", .{i});
        diags[i] = .{ .message = msgs[i], .severity = .error_, .line = @intCast(i), .col = 0, .end_line = @intCast(i), .end_col = 1 };
    }
    defer for (msgs) |m| testing.allocator.free(m);

    try reg.registerPending("zls", "file:///cap.zig", &diags);
    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);

    // Count rendered diagnostic lines (each starts with "Error file://...").
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Error /cap.zig:")) count += 1;
    }
    try testing.expectEqual(MAX_DIAGNOSTICS_PER_FILE, count);
}

test "lsp-03 total cap: 40 diagnostics across files are capped to 30" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    // 8 files x 5 errors each = 40 total, exceeding the 30 cap. Per-file (5) is
    // under the 10 cap so the only limit exercised is the running total.
    var all_msgs: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (all_msgs.items) |m| testing.allocator.free(m);
        all_msgs.deinit(testing.allocator);
    }
    for (0..8) |f| {
        var diags: [5]Diagnostic = undefined;
        for (0..5) |i| {
            const m = try std.fmt.allocPrint(testing.allocator, "f{d}e{d}", .{ f, i });
            try all_msgs.append(testing.allocator, m);
            diags[i] = .{ .message = m, .severity = .error_, .line = @intCast(i), .col = 0, .end_line = @intCast(i), .end_col = 1 };
        }
        const uri = try std.fmt.allocPrint(testing.allocator, "file:///f{d}.zig", .{f});
        defer testing.allocator.free(uri);
        try reg.registerPending("zls", uri, &diags);
    }

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Error /f")) count += 1;
    }
    try testing.expectEqual(MAX_TOTAL_DIAGNOSTICS, count);
}

test "lsp-03 mixed severities render Error-first even after caps" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const diags = [_]Diagnostic{
        .{ .message = "h1", .severity = .hint, .line = 0, .col = 0, .end_line = 0, .end_col = 1 },
        .{ .message = "e1", .severity = .error_, .line = 1, .col = 0, .end_line = 1, .end_col = 1 },
        .{ .message = "w1", .severity = .warning, .line = 2, .col = 0, .end_line = 2, .end_col = 1 },
        .{ .message = "i1", .severity = .info, .line = 3, .col = 0, .end_line = 3, .end_col = 1 },
    };
    try reg.registerPending("zls", "file:///sev.zig", &diags);
    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);

    const e = std.mem.indexOf(u8, out, "e1").?;
    const w = std.mem.indexOf(u8, out, "w1").?;
    const i = std.mem.indexOf(u8, out, "i1").?;
    const h = std.mem.indexOf(u8, out, "h1").?;
    try testing.expect(e < w);
    try testing.expect(w < i);
    try testing.expect(i < h);
}

test "lsp-03 resetAll clears cross-turn delivered tracking" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const d = Diagnostic{ .message = "r", .severity = .error_, .line = 0, .col = 0, .end_line = 0, .end_col = 1 };
    const diags = [_]Diagnostic{d};

    try reg.registerPending("zls", "file:///r.zig", &diags);
    const out1 = (try reg.checkForDiagnostics(testing.allocator)).?;
    testing.allocator.free(out1);

    // After resetAll the delivered set is gone, so the identical diagnostic
    // shows again on the next turn.
    reg.resetAll();
    try reg.registerPending("zls", "file:///r.zig", &diags);
    const out2 = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.indexOf(u8, out2, "r.zig") != null);
}

test "lsp-03 delivered LRU evicts the oldest URI past MAX_DELIVERED_FILES" {
    rt.installForTest();
    var reg = Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const d = Diagnostic{ .message = "z", .severity = .error_, .line = 0, .col = 0, .end_line = 0, .end_col = 1 };
    const diags = [_]Diagnostic{d};

    // Deliver one diagnostic for MAX_DELIVERED_FILES + 1 distinct URIs. The
    // first URI must be evicted, so re-publishing for it shows again (its
    // delivered set was dropped), while the most-recent URI stays deduped.
    var i: usize = 0;
    while (i < MAX_DELIVERED_FILES + 1) : (i += 1) {
        const uri = try std.fmt.allocPrint(testing.allocator, "file:///lru{d}.zig", .{i});
        defer testing.allocator.free(uri);
        try reg.registerPending("zls", uri, &diags);
        const out = (try reg.checkForDiagnostics(testing.allocator)).?;
        testing.allocator.free(out);
    }

    // file:///lru0.zig was the oldest and should have been evicted: re-publish
    // re-shows it.
    try reg.registerPending("zls", "file:///lru0.zig", &diags);
    const re = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(re);
    try testing.expect(std.mem.indexOf(u8, re, "lru0.zig") != null);

    // The most recent URI is still tracked: its identical re-publish is suppressed.
    const last_uri = try std.fmt.allocPrint(testing.allocator, "file:///lru{d}.zig", .{MAX_DELIVERED_FILES});
    defer testing.allocator.free(last_uri);
    try reg.registerPending("zls", last_uri, &diags);
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}
