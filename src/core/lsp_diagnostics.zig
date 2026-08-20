//! In-memory LSP diagnostic baseline tracking.
//!
//! Ports the reference's `diagnosticTracking.ts`: capture a baseline of the
//! diagnostics (errors / warnings) a language server reports for a file, then
//! on a later check surface only the diagnostics that are NEW since the
//! baseline. This is how the model learns "did my edit introduce a new error?"
//! without being flooded by pre-existing diagnostics it did not cause.
//!
//! Two pieces live here, both network-free and unit-testable:
//!   1. `parsePublishDiagnostics` -- pulls the diagnostics array out of a
//!      `textDocument/publishDiagnostics` notification. This is a NOTIFICATION
//!      (no `id`, method `textDocument/publishDiagnostics`), so the normal
//!      `extractLspResult` (which scans for `"result"`) does NOT find it. We
//!      scan for the method instead.
//!   2. `BaselineStore` -- a session-scoped, in-memory map keyed by file URI.
//!      `setBaseline(uri, diags)` records the baseline; `newSince(uri, current)`
//!      returns the diagnostics present now that were not in the baseline. A
//!      diagnostic is identified by its `(line, severity, message)` tuple, so
//!      moving a diagnostic to a different column is not treated as new but a
//!      genuinely new message is. No disk persistence -- matches the reference's
//!      per-session tracking.

const std = @import("std");

/// One LSP diagnostic, reduced to the fields we use for identity and display.
/// `line` is the 0-based start line from the LSP `range`. `severity` follows
/// the LSP convention (1=Error, 2=Warning, 3=Information, 4=Hint); 0 means the
/// server omitted it. `message` and `uri` are owned by the store once stored.
pub const Diagnostic = struct {
    line: u32,
    severity: u32,
    message: []const u8,

    /// Two diagnostics are the "same" for baseline purposes when their line,
    /// severity, and message all match. Column is intentionally excluded so a
    /// pre-existing diagnostic that shifts horizontally is not flagged as new.
    pub fn eql(a: Diagnostic, b: Diagnostic) bool {
        return a.line == b.line and a.severity == b.severity and
            std.mem.eql(u8, a.message, b.message);
    }

    /// Human-readable severity label for rendering.
    pub fn severityLabel(self: Diagnostic) []const u8 {
        return switch (self.severity) {
            1 => "error",
            2 => "warning",
            3 => "info",
            4 => "hint",
            else => "diagnostic",
        };
    }
};

/// Parse the diagnostics array out of `textDocument/publishDiagnostics`
/// notification(s) found in raw (possibly Content-Length-framed) JSON-RPC
/// output, restricted to the given file `uri`. Servers may emit several
/// notifications (incremental); we take the LAST one whose `params.uri`
/// matches, since that reflects the server's settled view of the file.
///
/// Returns owned `Diagnostic`s (each `message` is duped from `allocator`); the
/// caller owns the slice and every `message`. Use `freeDiagnostics` to release.
/// Returns an empty slice when no matching notification is present (this is a
/// valid "no diagnostics" result, not an error).
pub fn parsePublishDiagnostics(
    allocator: std.mem.Allocator,
    raw: []const u8,
    uri: []const u8,
) ![]Diagnostic {
    var collected = std.array_list.Managed(Diagnostic).init(allocator);
    errdefer {
        for (collected.items) |d| allocator.free(d.message);
        collected.deinit();
    }

    // Scan every JSON-RPC object in the stream. The last matching
    // publishDiagnostics wins, so we clear earlier results when a later
    // matching notification appears.
    var search = raw;
    while (std.mem.indexOf(u8, search, "{\"jsonrpc\"")) |idx| {
        const start = search[idx..];

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        if (std.json.parseFromSlice(std.json.Value, arena.allocator(), start, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                const method = obj.get("method");
                const is_publish = method != null and method.? == .string and
                    std.mem.eql(u8, method.?.string, "textDocument/publishDiagnostics");
                if (is_publish) {
                    if (obj.get("params")) |params| {
                        if (params == .object) {
                            const purl = params.object.get("uri");
                            const uri_match = purl != null and purl.? == .string and
                                std.mem.eql(u8, purl.?.string, uri);
                            if (uri_match) {
                                // Later notification supersedes earlier ones for
                                // this URI: drop what we had, take this set.
                                for (collected.items) |d| allocator.free(d.message);
                                collected.clearRetainingCapacity();
                                if (params.object.get("diagnostics")) |diags| {
                                    if (diags == .array) {
                                        for (diags.array.items) |dv| {
                                            if (dv != .object) continue;
                                            const d = try diagnosticFromValue(allocator, dv.object);
                                            try collected.append(d);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else |_| {}

        if (idx + 1 < search.len) {
            search = search[idx + 1 ..];
        } else break;
    }

    return collected.toOwnedSlice();
}

/// Build a `Diagnostic` from a parsed diagnostic JSON object. `message` is
/// duped from `allocator` so it outlives the parse arena.
fn diagnosticFromValue(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !Diagnostic {
    var line: u32 = 0;
    if (obj.get("range")) |range| {
        if (range == .object) {
            if (range.object.get("start")) |s| {
                if (s == .object) {
                    if (s.object.get("line")) |lv| {
                        if (lv == .integer and lv.integer >= 0)
                            line = @intCast(lv.integer);
                    }
                }
            }
        }
    }

    var severity: u32 = 0;
    if (obj.get("severity")) |sv| {
        if (sv == .integer and sv.integer >= 0) severity = @intCast(sv.integer);
    }

    const message = blk: {
        if (obj.get("message")) |mv| {
            if (mv == .string) break :blk try allocator.dupe(u8, mv.string);
        }
        break :blk try allocator.dupe(u8, "");
    };

    return .{ .line = line, .severity = severity, .message = message };
}

/// Free a diagnostics slice and each owned `message`, as returned by
/// `parsePublishDiagnostics`.
pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []Diagnostic) void {
    for (diags) |d| allocator.free(d.message);
    allocator.free(diags);
}

/// Session-scoped, in-memory baseline store keyed by file URI. Owns every URI
/// key and every stored `Diagnostic.message`. Not thread-safe (LSP calls are
/// driven from the single agent loop).
pub const BaselineStore = struct {
    allocator: std.mem.Allocator,
    /// uri -> owned baseline diagnostics.
    map: std.StringHashMapUnmanaged([]Diagnostic) = .{},

    pub fn init(allocator: std.mem.Allocator) BaselineStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BaselineStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeDiagnostics(self.allocator, entry.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    /// Record `diags` as the baseline for `uri`, replacing any prior baseline.
    /// The store takes its own copy of the URI and of each diagnostic message,
    /// so the caller may free its inputs afterward.
    pub fn setBaseline(self: *BaselineStore, uri: []const u8, diags: []const Diagnostic) !void {
        const owned = try self.dupeDiagnostics(diags);
        errdefer freeDiagnostics(self.allocator, owned);

        if (self.map.getEntry(uri)) |entry| {
            // Replace existing baseline; reuse the existing key.
            freeDiagnostics(self.allocator, entry.value_ptr.*);
            entry.value_ptr.* = owned;
            return;
        }
        const key = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(key);
        try self.map.put(self.allocator, key, owned);
    }

    /// True when a baseline has been recorded for `uri`.
    pub fn hasBaseline(self: *BaselineStore, uri: []const u8) bool {
        return self.map.contains(uri);
    }

    /// Return the diagnostics in `current` that are NOT present in the baseline
    /// for `uri`. When no baseline was recorded, every current diagnostic is
    /// considered new (the reference behavior: with nothing to compare against,
    /// surface everything). The returned slice is owned by `allocator` and each
    /// `message` is freshly duped; free with `freeDiagnostics`.
    pub fn newSince(
        self: *BaselineStore,
        allocator: std.mem.Allocator,
        uri: []const u8,
        current: []const Diagnostic,
    ) ![]Diagnostic {
        const baseline: []const Diagnostic = if (self.map.get(uri)) |b| b else &.{};
        const has_base = self.map.contains(uri);

        var out = std.array_list.Managed(Diagnostic).init(allocator);
        errdefer {
            for (out.items) |d| allocator.free(d.message);
            out.deinit();
        }

        for (current) |c| {
            const is_new = if (!has_base) true else !containsDiagnostic(baseline, c);
            if (is_new) {
                const msg = try allocator.dupe(u8, c.message);
                errdefer allocator.free(msg);
                try out.append(.{ .line = c.line, .severity = c.severity, .message = msg });
            }
        }

        return out.toOwnedSlice();
    }

    fn dupeDiagnostics(self: *BaselineStore, diags: []const Diagnostic) ![]Diagnostic {
        const owned = try self.allocator.alloc(Diagnostic, diags.len);
        var filled: usize = 0;
        errdefer {
            for (owned[0..filled]) |d| self.allocator.free(d.message);
            self.allocator.free(owned);
        }
        for (diags, 0..) |d, i| {
            const msg = try self.allocator.dupe(u8, d.message);
            owned[i] = .{ .line = d.line, .severity = d.severity, .message = msg };
            filled = i + 1;
        }
        return owned;
    }
};

/// True when `set` contains a diagnostic equal (line/severity/message) to `d`.
fn containsDiagnostic(set: []const Diagnostic, d: Diagnostic) bool {
    for (set) |s| {
        if (s.eql(d)) return true;
    }
    return false;
}

// --- Tests ---

const testing = std.testing;

test "newSince returns only diagnostics not in baseline" {
    var store = BaselineStore.init(testing.allocator);
    defer store.deinit();

    const a = Diagnostic{ .line = 1, .severity = 1, .message = "A" };
    const b = Diagnostic{ .line = 2, .severity = 2, .message = "B" };
    const c = Diagnostic{ .line = 3, .severity = 1, .message = "C" };

    try store.setBaseline("file:///x.zig", &.{ a, b });

    // current [A,B,C] -> [C]
    {
        const got = try store.newSince(testing.allocator, "file:///x.zig", &.{ a, b, c });
        defer freeDiagnostics(testing.allocator, got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqualStrings("C", got[0].message);
        try testing.expectEqual(@as(u32, 3), got[0].line);
    }

    // current [A] -> [] (a subset of baseline introduces nothing new)
    {
        const got = try store.newSince(testing.allocator, "file:///x.zig", &.{a});
        defer freeDiagnostics(testing.allocator, got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
}

test "newSince with no baseline treats everything as new" {
    var store = BaselineStore.init(testing.allocator);
    defer store.deinit();

    const a = Diagnostic{ .line = 1, .severity = 1, .message = "A" };
    const b = Diagnostic{ .line = 2, .severity = 1, .message = "B" };

    try testing.expect(!store.hasBaseline("file:///none.zig"));
    const got = try store.newSince(testing.allocator, "file:///none.zig", &.{ a, b });
    defer freeDiagnostics(testing.allocator, got);
    try testing.expectEqual(@as(usize, 2), got.len);
}

test "newSince distinguishes by severity and message, not column" {
    var store = BaselineStore.init(testing.allocator);
    defer store.deinit();

    const base = Diagnostic{ .line = 5, .severity = 2, .message = "unused var" };
    try store.setBaseline("file:///y.zig", &.{base});

    // Same line/severity/message -> not new, even with a different (unmodeled)
    // column. We only carry line/severity/message in the identity tuple.
    {
        const same = Diagnostic{ .line = 5, .severity = 2, .message = "unused var" };
        const got = try store.newSince(testing.allocator, "file:///y.zig", &.{same});
        defer freeDiagnostics(testing.allocator, got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    // Same line but the severity escalated (warning -> error) is genuinely new.
    {
        const escalated = Diagnostic{ .line = 5, .severity = 1, .message = "unused var" };
        const got = try store.newSince(testing.allocator, "file:///y.zig", &.{escalated});
        defer freeDiagnostics(testing.allocator, got);
        try testing.expectEqual(@as(usize, 1), got.len);
        try testing.expectEqual(@as(u32, 1), got[0].severity);
    }
}

test "setBaseline replaces a prior baseline for the same uri" {
    var store = BaselineStore.init(testing.allocator);
    defer store.deinit();

    try store.setBaseline("file:///z.zig", &.{.{ .line = 1, .severity = 1, .message = "old" }});
    try store.setBaseline("file:///z.zig", &.{.{ .line = 2, .severity = 1, .message = "new" }});

    // The old baseline must be gone: a current set matching the new baseline
    // yields nothing new, and one matching the old baseline does.
    const matches_new = try store.newSince(testing.allocator, "file:///z.zig", &.{.{ .line = 2, .severity = 1, .message = "new" }});
    defer freeDiagnostics(testing.allocator, matches_new);
    try testing.expectEqual(@as(usize, 0), matches_new.len);

    const matches_old = try store.newSince(testing.allocator, "file:///z.zig", &.{.{ .line = 1, .severity = 1, .message = "old" }});
    defer freeDiagnostics(testing.allocator, matches_old);
    try testing.expectEqual(@as(usize, 1), matches_old.len);
}

test "parsePublishDiagnostics extracts line, severity, message for the uri" {
    const raw =
        "Content-Length: 200\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///a.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":4,\"character\":2},\"end\":{\"line\":4,\"character\":9}},\"severity\":1,\"message\":\"expected ';'\"}," ++
        "{\"range\":{\"start\":{\"line\":10,\"character\":0},\"end\":{\"line\":10,\"character\":5}},\"severity\":2,\"message\":\"unused\"}" ++
        "]}}";

    const diags = try parsePublishDiagnostics(testing.allocator, raw, "file:///a.zig");
    defer freeDiagnostics(testing.allocator, diags);

    try testing.expectEqual(@as(usize, 2), diags.len);
    try testing.expectEqual(@as(u32, 4), diags[0].line);
    try testing.expectEqual(@as(u32, 1), diags[0].severity);
    try testing.expectEqualStrings("expected ';'", diags[0].message);
    try testing.expectEqualStrings("error", diags[0].severityLabel());
    try testing.expectEqual(@as(u32, 10), diags[1].line);
    try testing.expectEqual(@as(u32, 2), diags[1].severity);
    try testing.expectEqualStrings("warning", diags[1].severityLabel());
}

test "parsePublishDiagnostics ignores notifications for a different uri" {
    const raw =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///other.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":1,\"character\":0}},\"severity\":1,\"message\":\"x\"}]}}";

    const diags = try parsePublishDiagnostics(testing.allocator, raw, "file:///wanted.zig");
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}

test "parsePublishDiagnostics takes the last notification for a uri" {
    // Server emits an initial (stale) set, then a settled set. We keep the last.
    const raw =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///b.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":1,\"character\":0}},\"severity\":1,\"message\":\"stale\"}]}}" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///b.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":7,\"character\":0}},\"severity\":2,\"message\":\"settled\"}]}}";

    const diags = try parsePublishDiagnostics(testing.allocator, raw, "file:///b.zig");
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("settled", diags[0].message);
    try testing.expectEqual(@as(u32, 7), diags[0].line);
}

test "parsePublishDiagnostics returns empty for a clean file (no diagnostics)" {
    const raw =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///clean.zig\",\"diagnostics\":[]}}";
    const diags = try parsePublishDiagnostics(testing.allocator, raw, "file:///clean.zig");
    defer freeDiagnostics(testing.allocator, diags);
    try testing.expectEqual(@as(usize, 0), diags.len);
}
