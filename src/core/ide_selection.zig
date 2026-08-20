//! Editor selection sync (ide-integration-04).
//!
//! Handles the inbound `selection_changed` notification the IDE extension
//! pushes over the outbound MCP client (mcp/ide_client.zig), computes the
//! selected `line_count` / `line_start`, and renders the current editor
//! selection into the next prompt as an `<ide_selection>...</ide_selection>`
//! block. `core/display_tags.zig` already strips that block on UP-arrow
//! resubmit, so producer and consumer stay symmetric: anything `renderTag`
//! emits, `display_tags.stripIdeContextTags` removes.
//!
//! Reference (claude-code-main/src/hooks/useIdeSelection.ts):
//!   :32     SelectionChangedSchema =
//!             { method:'selection_changed',
//!               params:{ selection:{start:{line,character},
//!                                   end:{line,character}}|null,
//!                        text?, filePath? } }
//!   :91-108 selectionChangeHandler: lineCount = end.line - start.line + 1;
//!             if end.character === 0 -> lineCount-- (do not count a line
//!             whose selection ends at column 0); produce
//!             { lineCount, lineStart: start.line, text, filePath }.
//!   :131    selection null but text present -> treat as cleared selection.
//!
//! The reference's prompt-side rendering (utils/messages.ts:3613) caps the
//! embedded selection text at 2000 chars; we mirror that cap so a large
//! selection can't bloat the prompt.

const std = @import("std");
const display_tags = @import("display_tags.zig");
const std_io = @import("std_io.zig");

/// Cap on the embedded selection text length. Mirrors the reference's
/// maxSelectionLength (utils/messages.ts:3614). A longer selection is
/// truncated with a trailing marker.
pub const MAX_SELECTION_TEXT: usize = 2000;
const TRUNCATION_MARKER = "\n... (truncated)";

/// A parsed editor selection. All slices are owned and freed by `deinit`.
///
///   - `line_count`: number of selected lines per the reference formula
///     (`end.line - start.line + 1`, minus one when `end.character == 0`).
///     A cleared selection (selection:null) has `line_count == 0`.
///   - `line_start`: the selection's start line, or null when cleared.
///   - `text`: the selected text, or null when absent.
///   - `file_path`: the file the selection is in, or null when absent.
pub const Selection = struct {
    line_count: i64,
    line_start: ?i64,
    text: ?[]u8,
    file_path: ?[]u8,

    pub fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        if (self.text) |t| allocator.free(t);
        if (self.file_path) |p| allocator.free(p);
    }
};

const Point = struct { line: i64, character: i64 };

/// Parse a `selection_changed` notification's `params` JSON into a
/// `Selection`.
///
/// Returns:
///   - a populated `Selection` when `params.selection` has start+end,
///   - a cleared `Selection` (`line_count == 0`, `line_start == null`)
///     when `selection` is null/absent but `text` is present,
///   - `null` when neither a usable selection nor `text` is present
///     (nothing to surface).
///
/// On JSON parse failure returns `error.InvalidSelection`. The returned
/// `Selection` owns its `text` / `file_path` in `allocator`.
pub fn parseSelectionChanged(
    allocator: std.mem.Allocator,
    params_json: []const u8,
) !?Selection {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, params_json, .{}) catch
        return error.InvalidSelection;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSelection;
    const params = parsed.value.object;

    const text = optString(params.get("text"));
    const file_path = optString(params.get("filePath"));

    if (parsePoints(params.get("selection"))) |pts| {
        // Active selection: apply the reference line-count formula.
        var line_count = pts.end.line - pts.start.line + 1;
        // If the selection ends at the first character of a line, that line
        // is not actually selected -- drop it (useIdeSelection.ts:97-99).
        if (pts.end.character == 0) line_count -= 1;

        return Selection{
            .line_count = line_count,
            .line_start = pts.start.line,
            .text = try dupOptCapped(allocator, text),
            .file_path = try dupOpt(allocator, file_path),
        };
    }

    // No active selection. If `text` is present (e.g. ""), treat it as a
    // cleared selection rather than dropping the event (reference :131).
    if (text != null) {
        return Selection{
            .line_count = 0,
            .line_start = null,
            .text = try dupOptCapped(allocator, text),
            .file_path = try dupOpt(allocator, file_path),
        };
    }

    // Neither a selection nor text -- nothing usable.
    return null;
}

/// Render a `Selection` into an `<ide_selection>...</ide_selection>` block
/// suitable for prepending to the user prompt. The block is shaped so
/// `display_tags.stripIdeContextTags` removes it cleanly on resubmit
/// (lowercase tag name, matching close tag, no stray `</ide_selection>` in
/// the body). Caller owns the returned slice.
///
/// A cleared selection (no line_start / no text) renders to an empty
/// string -- there is nothing to surface.
pub fn renderTag(allocator: std.mem.Allocator, sel: Selection) ![]u8 {
    // Nothing meaningful to show.
    if (sel.line_start == null and sel.text == null) {
        return allocator.dupe(u8, "");
    }

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();

    try w.writeAll("<ide_selection>");
    if (sel.file_path) |fp| {
        try w.writeAll("The user selected ");
        if (sel.line_start) |start| {
            const end = start + sel.line_count - 1;
            try w.print("lines {d} to {d} of ", .{ start, end });
        }
        try w.writeAll(fp);
    } else {
        try w.writeAll("The user has a selection in the IDE");
    }
    if (sel.text) |t| {
        // Strip any literal close tag from the body so the block stays a
        // single matched pair (defensive -- selection text should never
        // contain it, but if it did the non-greedy strip would end early).
        try w.writeAll(":\n");
        try writeSanitized(w, t);
    }
    try w.writeAll("</ide_selection>");

    return buf.toOwnedSlice();
}

// -- helpers ---------------------------------------------------------------

/// Extract a JSON value as a string, or null if absent / not a string.
fn optString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Parse the `selection` object into start/end points, or null if the
/// value is missing / null / malformed (no usable start+end).
fn parsePoints(v: ?std.json.Value) ?struct { start: Point, end: Point } {
    const val = v orelse return null;
    if (val != .object) return null;
    const obj = val.object;
    const start = parsePoint(obj.get("start")) orelse return null;
    const end = parsePoint(obj.get("end")) orelse return null;
    return .{ .start = start, .end = end };
}

fn parsePoint(v: ?std.json.Value) ?Point {
    const val = v orelse return null;
    if (val != .object) return null;
    const obj = val.object;
    const line = asInt(obj.get("line")) orelse return null;
    const character = asInt(obj.get("character")) orelse return null;
    return .{ .line = line, .character = character };
}

/// Coerce a JSON number to i64 (integer or float). Null if not numeric.
fn asInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn dupOpt(allocator: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    const str = s orelse return null;
    return try allocator.dupe(u8, str);
}

/// Dup a string, truncating to MAX_SELECTION_TEXT with a trailing marker
/// (mirrors the reference's selection-length cap).
fn dupOptCapped(allocator: std.mem.Allocator, s: ?[]const u8) !?[]u8 {
    const str = s orelse return null;
    if (str.len <= MAX_SELECTION_TEXT) return try allocator.dupe(u8, str);
    const head = str[0..MAX_SELECTION_TEXT];
    return try std.mem.concat(allocator, u8, &.{ head, TRUNCATION_MARKER });
}

/// Write `text`, replacing any literal `</ide_selection>` so the rendered
/// block remains a single well-formed pair that strips cleanly.
fn writeSanitized(w: anytype, text: []const u8) !void {
    const close = "</ide_selection>";
    var rest = text;
    while (std.mem.indexOf(u8, rest, close)) |idx| {
        try w.writeAll(rest[0..idx]);
        try w.writeAll("<\\/ide_selection>");
        rest = rest[idx + close.len ..];
    }
    try w.writeAll(rest);
}

// -- Tests ------------------------------------------------------------------

const testing = std.testing;

test "parseSelectionChanged computes line_count and line_start" {
    const json =
        "{\"selection\":{\"start\":{\"line\":3,\"character\":2}," ++
        "\"end\":{\"line\":7,\"character\":5}},\"text\":\"hi\",\"filePath\":\"/a.zig\"}";
    var sel = (try parseSelectionChanged(testing.allocator, json)).?;
    defer sel.deinit(testing.allocator);
    // 7 - 3 + 1 = 5, end.character != 0 so no decrement.
    try testing.expectEqual(@as(i64, 5), sel.line_count);
    try testing.expectEqual(@as(?i64, 3), sel.line_start);
    try testing.expectEqualStrings("hi", sel.text.?);
    try testing.expectEqualStrings("/a.zig", sel.file_path.?);
}

test "parseSelectionChanged decrements line_count when end.character == 0" {
    const json =
        "{\"selection\":{\"start\":{\"line\":3,\"character\":2}," ++
        "\"end\":{\"line\":7,\"character\":0}}}";
    var sel = (try parseSelectionChanged(testing.allocator, json)).?;
    defer sel.deinit(testing.allocator);
    // 7 - 3 + 1 = 5, minus one for the column-0 end = 4.
    try testing.expectEqual(@as(i64, 4), sel.line_count);
    try testing.expectEqual(@as(?i64, 3), sel.line_start);
}

test "parseSelectionChanged treats null selection with text as cleared" {
    const json = "{\"selection\":null,\"text\":\"\"}";
    var sel = (try parseSelectionChanged(testing.allocator, json)).?;
    defer sel.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), sel.line_count);
    try testing.expectEqual(@as(?i64, null), sel.line_start);
    try testing.expectEqualStrings("", sel.text.?);
}

test "parseSelectionChanged returns null when nothing usable" {
    const json = "{\"filePath\":\"/a.zig\"}";
    const sel = try parseSelectionChanged(testing.allocator, json);
    try testing.expect(sel == null);
}

test "parseSelectionChanged caps oversized text" {
    var big: std.ArrayListUnmanaged(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "{\"selection\":null,\"text\":\"");
    try big.appendNTimes(testing.allocator, 'x', MAX_SELECTION_TEXT + 50);
    try big.appendSlice(testing.allocator, "\"}");

    var sel = (try parseSelectionChanged(testing.allocator, big.items)).?;
    defer sel.deinit(testing.allocator);
    // MAX chars + the truncation marker.
    try testing.expectEqual(MAX_SELECTION_TEXT + TRUNCATION_MARKER.len, sel.text.?.len);
    try testing.expect(std.mem.endsWith(u8, sel.text.?, TRUNCATION_MARKER));
}

test "renderTag round-trips: stripIdeContextTags removes it entirely" {
    var sel = Selection{
        .line_count = 5,
        .line_start = 3,
        .text = try testing.allocator.dupe(u8, "const x = 1;\nconst y = 2;"),
        .file_path = try testing.allocator.dupe(u8, "/src/a.zig"),
    };
    defer sel.deinit(testing.allocator);

    const tag = try renderTag(testing.allocator, sel);
    defer testing.allocator.free(tag);
    try testing.expect(std.mem.startsWith(u8, tag, "<ide_selection>"));
    try testing.expect(std.mem.endsWith(u8, tag, "</ide_selection>"));

    // Round-trip symmetry: the producer's output is fully stripped by the
    // consumer (display_tags.zig), so resubmit never carries IDE metadata.
    const stripped = try display_tags.stripIdeContextTags(testing.allocator, tag);
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings("", stripped);
}

test "renderTag round-trips even with a close tag embedded in the text" {
    var sel = Selection{
        .line_count = 1,
        .line_start = 1,
        // Pathological: the selected text literally contains the close tag.
        .text = try testing.allocator.dupe(u8, "before </ide_selection> after"),
        .file_path = try testing.allocator.dupe(u8, "/x.zig"),
    };
    defer sel.deinit(testing.allocator);

    const tag = try renderTag(testing.allocator, sel);
    defer testing.allocator.free(tag);

    const stripped = try display_tags.stripIdeContextTags(testing.allocator, tag);
    defer testing.allocator.free(stripped);
    // Sanitizing the body keeps the block a single matched pair, so the
    // whole thing still strips to empty.
    try testing.expectEqualStrings("", stripped);
}

test "renderTag of a cleared selection is empty" {
    var sel = Selection{
        .line_count = 0,
        .line_start = null,
        .text = null,
        .file_path = null,
    };
    defer sel.deinit(testing.allocator);
    const tag = try renderTag(testing.allocator, sel);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

test "parseSelectionChanged surfaces InvalidSelection on bad JSON" {
    try testing.expectError(
        error.InvalidSelection,
        parseSelectionChanged(testing.allocator, "not json"),
    );
}
