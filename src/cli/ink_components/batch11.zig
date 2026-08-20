//! #575: Ink component batch 11 - diff, code-highlight, select, search components.
//!
//! Minimal ports of reference diff/, HighlightedCode, CustomSelect,
//! and search-dialog components.

const std = @import("std");
const ink_render = @import("../../core/ink_render.zig");
const ink_layout = @import("../../core/ink_layout.zig");

// --- DiffDialog / DiffFileList / DiffDetailView ---
// The reference's diff components render a file list + a per-file diff
// view. zcode's version captures the data model.

pub const DiffFileEntry = struct {
    path: []const u8,
    additions: u32,
    deletions: u32,
    selected: bool = false,
};

pub fn renderDiffFileList(allocator: std.mem.Allocator, files: []const DiffFileEntry) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    for (files) |f| {
        const prefix: []const u8 = if (f.selected) "› " else "  ";
        try buf.writer.print("{s}{s} (+{d} -{d})\n", .{ prefix, f.path, f.additions, f.deletions });
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{},
    };
}

pub const DiffDetailProps = struct {
    path: []const u8,
    additions: u32,
    deletions: u32,
    hunks: u32,
};

pub fn renderDiffDetail(allocator: std.mem.Allocator, props: DiffDetailProps) !ink_render.RenderCommand {
    return .{
        .node_id = 0,
        .text = try std.fmt.allocPrint(allocator, "{s}  +{d} -{d}  {d} hunk(s)", .{ props.path, props.additions, props.deletions, props.hunks }),
        .style = .{ .bold = true },
    };
}

// --- HighlightedCode ---
// Renders syntax-highlighted code. The reference uses a highlighter
// (Shiki/highlight.js) to produce ANSI-colored spans. zcode's version
// is a passthrough: it returns the code as-is (no highlighting) since
// zcode gates highlighting on CLAUDE_CODE_SYNTAX_HIGHLIGHT (defaults on
// in zcode per the wiki). The actual highlighter integration is a
// larger follow-up.
pub const HighlightedCodeProps = struct {
    code: []const u8,
    language: ?[]const u8 = null,
};

pub fn renderHighlightedCode(allocator: std.mem.Allocator, props: HighlightedCodeProps) !ink_render.RenderCommand {
    // Passthrough: no syntax highlighting in the minimal port.
    // The language is recorded for when a highlighter is wired in.
    _ = props.language;
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, props.code),
        .style = .{},
    };
}

// --- CustomSelect ---
// A scrollable selectable list. The reference's CustomSelect handles
// keyboard nav (up/down/enter), filtering, and rendering. zcode's
// version is the state model.
pub const CustomSelect = struct {
    options: []const []const u8,
    selected_index: usize = 0,
    scroll_offset: usize = 0,
    max_visible: usize = 10,
    filter: ?[]const u8 = null,

    pub fn visibleStart(self: CustomSelect) usize {
        return self.scroll_offset;
    }

    pub fn visibleEnd(self: CustomSelect) usize {
        const end = self.scroll_offset + self.max_visible;
        return @min(end, self.options.len);
    }

    pub fn moveDown(self: *CustomSelect) void {
        if (self.selected_index + 1 < self.options.len) {
            self.selected_index += 1;
            if (self.selected_index >= self.visibleEnd()) {
                self.scroll_offset = self.selected_index + 1 - self.max_visible;
            }
        }
    }

    pub fn moveUp(self: *CustomSelect) void {
        if (self.selected_index > 0) {
            self.selected_index -= 1;
            if (self.selected_index < self.visibleStart()) {
                self.scroll_offset = self.selected_index;
            }
        }
    }

    pub fn currentOption(self: CustomSelect) ?[]const u8 {
        if (self.options.len == 0) return null;
        return self.options[self.selected_index];
    }
};

// --- GlobalSearchDialog ---
// Full-text search across files. State: query, results, selected.
pub const SearchResult = struct {
    path: []const u8,
    line: u32,
    preview: []const u8,
};

pub const GlobalSearch = struct {
    query: []const u8 = "",
    results: []const SearchResult = &.{},
    selected_index: usize = 0,
};

pub fn renderGlobalSearch(allocator: std.mem.Allocator, search: GlobalSearch) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.print("Search: {s}\n", .{search.query});
    for (search.results, 0..) |r, i| {
        const prefix: []const u8 = if (i == search.selected_index) "› " else "  ";
        try buf.writer.print("{s}{s}:{d}: {s}\n", .{ prefix, r.path, r.line, r.preview });
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{},
    };
}

// --- HistorySearchDialog ---
pub const HistorySearch = struct {
    query: []const u8 = "",
    sessions: []const []const u8 = &.{},
    selected_index: usize = 0,
};

pub fn renderHistorySearch(allocator: std.mem.Allocator, search: HistorySearch) !ink_render.RenderCommand {
    var buf = std.Io.Writer.Allocating.init(allocator);
    errdefer buf.deinit();
    try buf.writer.print("History search: {s}\n", .{search.query});
    for (search.sessions, 0..) |s, i| {
        const prefix: []const u8 = if (i == search.selected_index) "› " else "  ";
        try buf.writer.print("{s}{s}\n", .{ prefix, s });
    }
    return .{
        .node_id = 0,
        .text = try allocator.dupe(u8, buf.writer.buffered()),
        .style = .{},
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "renderDiffFileList: shows each file with +/-" {
    const files = [_]DiffFileEntry{
        .{ .path = "a.zig", .additions = 3, .deletions = 1, .selected = true },
        .{ .path = "b.zig", .additions = 0, .deletions = 2 },
    };
    const cmd = try renderDiffFileList(testing.allocator, &files);
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "a.zig") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "+3") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "›") != null); // selected marker
}

test "renderDiffDetail: includes path + counts + hunk count" {
    const cmd = try renderDiffDetail(testing.allocator, .{ .path = "a.zig", .additions = 5, .deletions = 2, .hunks = 3 });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "3 hunk") != null);
    try testing.expect(cmd.style.bold);
}

test "renderHighlightedCode: passthrough returns the code unchanged" {
    const cmd = try renderHighlightedCode(testing.allocator, .{ .code = "fn main() {}", .language = "zig" });
    defer testing.allocator.free(cmd.text);
    try testing.expectEqualStrings("fn main() {}", cmd.text);
}

test "CustomSelect.moveDown advances and scrolls" {
    const opts = [_][]const u8{ "a", "b", "c", "d", "e" };
    var sel = CustomSelect{ .options = &opts, .max_visible = 2 };
    try testing.expectEqual(@as(usize, 0), sel.selected_index);
    sel.moveDown();
    try testing.expectEqual(@as(usize, 1), sel.selected_index);
    sel.moveDown();
    try testing.expectEqual(@as(usize, 2), sel.selected_index);
    try testing.expectEqual(@as(usize, 1), sel.scroll_offset); // scrolled
}

test "CustomSelect.moveUp at 0 is no-op" {
    const opts = [_][]const u8{ "a", "b" };
    var sel = CustomSelect{ .options = &opts };
    sel.moveUp();
    try testing.expectEqual(@as(usize, 0), sel.selected_index);
}

test "CustomSelect.currentOption returns the selected option" {
    const opts = [_][]const u8{ "a", "b" };
    var sel = CustomSelect{ .options = &opts, .selected_index = 1 };
    try testing.expectEqualStrings("b", sel.currentOption().?);
}

test "renderGlobalSearch: shows query + results with selected marker" {
    const results = [_]SearchResult{
        .{ .path = "a.zig", .line = 10, .preview = "match" },
    };
    const cmd = try renderGlobalSearch(testing.allocator, .{ .query = "foo", .results = &results });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "Search: foo") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "a.zig:10") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "›") != null); // selected
}

test "renderHistorySearch: shows query + sessions" {
    const sessions = [_][]const u8{ "session-1", "session-2" };
    const cmd = try renderHistorySearch(testing.allocator, .{ .query = "test", .sessions = &sessions });
    defer testing.allocator.free(cmd.text);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "History search: test") != null);
    try testing.expect(std.mem.indexOf(u8, cmd.text, "session-1") != null);
}
