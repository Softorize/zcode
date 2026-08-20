const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const helpers = @import("helpers.zig");
const file_tool = @import("file.zig");

/// Jupyter notebook edit modes. Ports the `edit_mode` field from
/// claude-code-main/src/tools/NotebookEditTool/NotebookEditTool.ts.
///
///   append   -- zcode-native default: add a new cell at the end
///               of the notebook. cell_number is ignored. Back
///               compat with the old single-mode signature.
///   replace  -- reference default: replace the cell at
///               cell_number with the new source.
///   insert   -- insert a new cell at index cell_number, pushing
///               later cells down.
///   delete   -- delete the cell at cell_number.
pub const EditMode = enum {
    append,
    replace,
    insert,
    delete,

    pub fn parse(raw: ?[]const u8) EditMode {
        const name = raw orelse return .append;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return .append;
        if (std.ascii.eqlIgnoreCase(trimmed, "replace")) return .replace;
        if (std.ascii.eqlIgnoreCase(trimmed, "insert")) return .insert;
        if (std.ascii.eqlIgnoreCase(trimmed, "delete")) return .delete;
        if (std.ascii.eqlIgnoreCase(trimmed, "remove")) return .delete;
        if (std.ascii.eqlIgnoreCase(trimmed, "append")) return .append;
        if (std.ascii.eqlIgnoreCase(trimmed, "add")) return .append;
        return .append;
    }
};

/// Back-compat entry point: append-only signature for callers that
/// haven't been updated to pass cell_number / edit_mode. Equivalent
/// to `notebookEditAt(..., cell_number=0, edit_mode=.append)`.
pub fn notebookEdit(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    notebook_path: []const u8,
    source: []const u8,
    cell_type: []const u8,
) ![]u8 {
    return notebookEditAt(allocator, cwd, notebook_path, source, cell_type, 0, .append);
}

/// Full-featured notebook editor. Dispatches to the byte-splicing
/// append path for .append (preserves existing formatting from
/// nbformat/jupyter) and to a reserialize path for replace/insert/
/// delete (which need cell-level surgery that's awkward to do with
/// raw-byte splicing).
fn writeNotebookAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

pub fn notebookEditAt(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    notebook_path: []const u8,
    source: []const u8,
    cell_type: []const u8,
    cell_number: usize,
    edit_mode: EditMode,
) ![]u8 {
    const abs = try helpers.normalizePath(allocator, cwd, notebook_path);
    defer allocator.free(abs);

    // Same device guard the Write / Edit / MultiEdit tools use
    // (passes 86-87). A model that called NotebookEdit('/dev/zero')
    // would otherwise read until our 2 MiB cap, then write a regular
    // .ipynb-shaped file in place of the device entry.
    if (file_tool.isBlockedDevicePath(notebook_path) or
        file_tool.isBlockedDevicePath(abs))
    {
        return std.fmt.allocPrint(
            allocator,
            "error: cannot edit '{s}': this device file would block, produce infinite output, or be replaced by the rename.",
            .{notebook_path},
        );
    }
    {
        // Kernel-authoritative stat check; allows /dev/null which is
        // pointless to edit but legal by convention.
        const st = std.Io.Dir.cwd().statFile(rt.io, abs, .{}) catch null;
        if (st) |s| {
            if ((s.kind == .character_device or s.kind == .block_device) and
                !std.mem.eql(u8, abs, "/dev/null"))
            {
                return std.fmt.allocPrint(
                    allocator,
                    "error: cannot edit '{s}': writing to a device file is refused.",
                    .{notebook_path},
                );
            }
        }
    }

    const dir_path = std.fs.path.dirname(abs) orelse cwd;
    std.Io.Dir.cwd().createDirPath(rt.io, dir_path) catch |err| {
        std.log.warn("notebook: failed to create dir: {s}", .{@errorName(err)});
    };

    const maybe_existing = std.Io.Dir.cwd().readFileAlloc(rt.io, abs, allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (maybe_existing) |existing| allocator.free(existing);

    const cell_json = try buildNotebookCellJson(allocator, source, cell_type);
    defer allocator.free(cell_json);

    // For append mode, stick with the existing byte-splicing path
    // so we preserve nbformat's formatting. For the other modes we
    // need cell-level surgery that's easier with a full parse.
    const final_json = blk: {
        switch (edit_mode) {
            .append => {
                if (maybe_existing) |existing| {
                    break :blk try appendNotebookCell(allocator, existing, cell_json);
                }
                break :blk try createNotebookJson(allocator, cell_json);
            },
            .replace, .insert, .delete => {
                if (maybe_existing) |existing| {
                    break :blk try applyIndexedEdit(allocator, existing, source, cell_type, cell_number, edit_mode);
                }
                // No existing notebook. replace on a missing file is
                // nonsense (no cell at that index); insert at 0 and
                // delete at 0 are both satisfied by "the file now
                // has one cell" or "the file now has zero cells".
                if (edit_mode == .replace or edit_mode == .delete) {
                    return std.fmt.allocPrint(
                        allocator,
                        "notebook edit failed: cannot {s} cell {d} in '{s}' -- file does not exist",
                        .{ @tagName(edit_mode), cell_number, notebook_path },
                    );
                }
                // insert at any index into an empty notebook = single-cell notebook
                break :blk try createNotebookJson(allocator, cell_json);
            },
        }
    };
    defer allocator.free(final_json);

    // Atomic write: a SIGINT in the truncate->writeAll window would
    // leave the .ipynb file at 0 bytes (or a partial JSON), and
    // every notebook reader rejects that as a parse error. Stage
    // into a sibling .tmp.<hex-nonce>, fsync, rename. Same pattern
    // as the atomic-write sweep (passes 64-70).
    try writeNotebookAtomic(allocator, abs, final_json);

    return switch (edit_mode) {
        .append => std.fmt.allocPrint(allocator, "notebook updated: {s} (appended cell)", .{notebook_path}),
        .replace => std.fmt.allocPrint(allocator, "notebook updated: {s} (replaced cell {d})", .{ notebook_path, cell_number }),
        .insert => std.fmt.allocPrint(allocator, "notebook updated: {s} (inserted cell at {d})", .{ notebook_path, cell_number }),
        .delete => std.fmt.allocPrint(allocator, "notebook updated: {s} (deleted cell {d})", .{ notebook_path, cell_number }),
    };
}

/// Re-serialize path for replace/insert/delete. Parses the full
/// notebook, manipulates the cells array by index, and emits a
/// fresh JSON document. Some original formatting is lost but the
/// nbformat structure is preserved -- Jupyter reads the fields,
/// not the whitespace.
fn applyIndexedEdit(
    allocator: std.mem.Allocator,
    notebook: []const u8,
    source: []const u8,
    cell_type: []const u8,
    cell_number: usize,
    edit_mode: EditMode,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, notebook, .{}) catch {
        return std.fmt.allocPrint(
            allocator,
            "notebook edit failed: existing file is not valid JSON. Read the file and fix it manually before editing.",
            .{},
        );
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return std.fmt.allocPrint(
            allocator,
            "notebook edit failed: root value is not an object -- does not look like a Jupyter notebook.",
            .{},
        );
    }
    var root = &parsed.value.object;

    const cells_value = root.get("cells") orelse {
        return std.fmt.allocPrint(
            allocator,
            "notebook edit failed: existing file has no `cells` array.",
            .{},
        );
    };
    if (cells_value != .array) {
        return std.fmt.allocPrint(
            allocator,
            "notebook edit failed: `cells` is not an array.",
            .{},
        );
    }
    const existing_cells = cells_value.array.items;

    // Bounds checking mirrors the reference behavior: replace/delete
    // require the index to exist; insert accepts one past the end
    // (so `insert at len` appends).
    switch (edit_mode) {
        .replace, .delete => {
            if (cell_number >= existing_cells.len) {
                return std.fmt.allocPrint(
                    allocator,
                    "notebook edit failed: cell_number {d} is out of range (notebook has {d} cells, valid indices are 0..{d})",
                    .{ cell_number, existing_cells.len, if (existing_cells.len == 0) @as(usize, 0) else existing_cells.len - 1 },
                );
            }
        },
        .insert => {
            if (cell_number > existing_cells.len) {
                return std.fmt.allocPrint(
                    allocator,
                    "notebook edit failed: cell_number {d} is out of range for insert (valid inserts are 0..{d}, where {d} appends)",
                    .{ cell_number, existing_cells.len, existing_cells.len },
                );
            }
        },
        .append => unreachable,
    }

    // Build the new cell if we need one.
    var new_cell_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (new_cell_parsed) |*p| p.deinit();
    const new_cell: ?std.json.Value = blk: {
        if (edit_mode == .delete) break :blk null;
        const cell_bytes = try buildNotebookCellJson(allocator, source, cell_type);
        defer allocator.free(cell_bytes);
        // Drop leading whitespace so parseFromSlice accepts our
        // prettified payload.
        const trimmed = std.mem.trimStart(u8, cell_bytes, " \t\r\n");
        new_cell_parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
        break :blk new_cell_parsed.?.value;
    };

    // Compose the new cells array.
    var next_cells = std.array_list.Managed(std.json.Value).init(allocator);
    defer next_cells.deinit();
    try next_cells.ensureTotalCapacity(existing_cells.len + 1);

    switch (edit_mode) {
        .replace => {
            for (existing_cells, 0..) |cell, idx| {
                if (idx == cell_number) {
                    try next_cells.append(new_cell.?);
                } else {
                    try next_cells.append(cell);
                }
            }
        },
        .insert => {
            for (existing_cells, 0..) |cell, idx| {
                if (idx == cell_number) try next_cells.append(new_cell.?);
                try next_cells.append(cell);
            }
            if (cell_number == existing_cells.len) {
                try next_cells.append(new_cell.?);
            }
        },
        .delete => {
            for (existing_cells, 0..) |cell, idx| {
                if (idx == cell_number) continue;
                try next_cells.append(cell);
            }
        },
        .append => unreachable,
    }

    // Replace the root object's `cells` entry with our rebuilt
    // array and re-serialize.
    const next_array_value = std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, try next_cells.toOwnedSlice()) };
    var next_array_mut = next_array_value;
    defer next_array_mut.array.deinit();

    // Use the parsed arena allocator so we don't try to free arena-managed
    // entry bytes with the test allocator (caused 'Invalid free' in 0.16).
    try root.put(parsed.arena.allocator(), "cells", next_array_value);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    try out.append('\n');
    return out.toOwnedSlice();
}

fn appendNotebookCell(allocator: std.mem.Allocator, notebook: []const u8, cell_json: []const u8) ![]u8 {
    // Parse the existing notebook via std.json rather than scanning for a
    // literal "cells" substring. The previous implementation could match
    // an earlier unescaped "cells" value embedded in notebook metadata
    // (e.g. `{"kernelspec":{"name":"cells"}}` appearing before the real
    // cells key) and corrupt the file by splicing into the wrong array.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, notebook, .{}) catch {
        // Malformed existing file — start from scratch rather than
        // compounding the corruption.
        return createNotebookJson(allocator, cell_json);
    };
    defer parsed.deinit();

    if (parsed.value != .object) return createNotebookJson(allocator, cell_json);
    const root = parsed.value.object;
    const cells_value = root.get("cells") orelse return createNotebookJson(allocator, cell_json);
    if (cells_value != .array) return createNotebookJson(allocator, cell_json);
    const cells = cells_value.array;

    // Locate the real `cells` key in the raw bytes so we can splice the new
    // cell in without fully re-serializing the notebook (which would drop
    // formatting that tools like nbformat produce). We use the parser only
    // to tell us whether the array exists and whether it is empty.
    const key_idx = findTopLevelKey(notebook, "cells") orelse return createNotebookJson(allocator, cell_json);
    const array_start = std.mem.indexOfScalarPos(u8, notebook, key_idx, '[') orelse return createNotebookJson(allocator, cell_json);
    const array_end = helpers.findMatchingBracket(notebook, array_start, '[', ']') orelse return createNotebookJson(allocator, cell_json);

    const has_cells = cells.items.len > 0;

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try out.appendSlice(notebook[0..array_end]);
    if (has_cells) try w.writeAll(",\n") else try w.writeAll("\n");
    try out.appendSlice(cell_json);
    try w.writeAll("\n");
    try out.appendSlice(notebook[array_end..]);
    return out.toOwnedSlice();
}

/// Return the byte offset of the top-level JSON object key `name` within
/// `notebook`, walking past string values and nested objects/arrays so we
/// do not match a `"name"` that appears as a value or inside metadata.
fn findTopLevelKey(notebook: []const u8, name: []const u8) ?usize {
    var i: usize = 0;
    // Skip leading whitespace and find the opening brace of the root object.
    while (i < notebook.len and std.ascii.isWhitespace(notebook[i])) : (i += 1) {}
    if (i >= notebook.len or notebook[i] != '{') return null;
    i += 1;

    var depth: usize = 0;
    var in_string = false;
    while (i < notebook.len) : (i += 1) {
        const ch = notebook[i];
        if (in_string) {
            if (ch == '\\' and i + 1 < notebook.len) {
                i += 1;
                continue;
            }
            if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => {
                if (depth == 0) {
                    // Potential top-level key start. Find the closing quote.
                    const key_start = i + 1;
                    var j = key_start;
                    while (j < notebook.len) : (j += 1) {
                        if (notebook[j] == '\\' and j + 1 < notebook.len) {
                            j += 1;
                            continue;
                        }
                        if (notebook[j] == '"') break;
                    }
                    if (j >= notebook.len) return null;
                    if (std.mem.eql(u8, notebook[key_start..j], name)) {
                        return i;
                    }
                    i = j; // advance past the key string
                    continue;
                }
                in_string = true;
            },
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) return null; // end of root object
                depth -= 1;
            },
            else => {},
        }
    }
    return null;
}

fn createNotebookJson(allocator: std.mem.Allocator, cell_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\n  \"cells\": [\n{s}\n  ],\n  \"metadata\": {{}},\n  \"nbformat\": 4,\n  \"nbformat_minor\": 5\n}}\n",
        .{cell_json},
    );
}

fn buildNotebookCellJson(allocator: std.mem.Allocator, source: []const u8, cell_type: []const u8) ![]u8 {
    const src_json = try buildNotebookSourceArray(allocator, source);
    defer allocator.free(src_json);

    if (std.mem.eql(u8, cell_type, "markdown")) {
        return std.fmt.allocPrint(
            allocator,
            "    {{\"cell_type\":\"markdown\",\"metadata\":{{}},\"source\":{s}}}",
            .{src_json},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "    {{\"cell_type\":\"code\",\"execution_count\":null,\"metadata\":{{}},\"outputs\":[],\"source\":{s}}}",
        .{src_json},
    );
}

fn buildNotebookSourceArray(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();
    try w.writeByte('[');

    if (source.len == 0) {
        try w.writeAll("\"\"");
        try w.writeByte(']');
        return out.toOwnedSlice();
    }

    var start: usize = 0;
    var idx: usize = 0;
    while (start <= source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..nl];
        const has_more = nl < source.len;

        if (idx > 0) try w.writeByte(',');
        const escaped = try helpers.jsonEscapeAlloc(allocator, line);
        defer allocator.free(escaped);
        if (has_more) {
            try w.print("\"{s}\\n\"", .{escaped});
        } else {
            try w.print("\"{s}\"", .{escaped});
        }

        idx += 1;
        if (!has_more) break;
        start = nl + 1;
    }

    try w.writeByte(']');
    return out.toOwnedSlice();
}

const testing = std.testing;
test "createNotebookJson structure" {
    const alloc = testing.allocator;
    const r = try createNotebookJson(alloc, "{}");
    defer alloc.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "\"cells\"") != null);
}
test "buildNotebookSourceArray empty" {
    const alloc = testing.allocator;
    const r = try buildNotebookSourceArray(alloc, "");
    defer alloc.free(r);
    try testing.expectEqualStrings("[\"\"]", r);
}

test "findTopLevelKey skips metadata values that contain the key name" {
    // Metadata appears BEFORE cells AND contains a string value that looks
    // like the cells key. The old indexOf-based search would latch onto the
    // metadata occurrence and splice into the wrong array.
    const notebook =
        \\{
        \\  "metadata": {"kernelspec": {"name": "cells"}},
        \\  "cells": [],
        \\  "nbformat": 4
        \\}
    ;
    const idx = findTopLevelKey(notebook, "cells") orelse return error.NotFound;
    // The index should point at the `"` of the top-level `"cells"` key,
    // which comes AFTER the metadata block.
    try testing.expect(idx > std.mem.indexOf(u8, notebook, "metadata").?);
    try testing.expectEqualStrings("\"cells\"", notebook[idx .. idx + 7]);
}

test "appendNotebookCell survives metadata containing cells string" {
    const alloc = testing.allocator;
    const notebook =
        \\{
        \\  "metadata": {"note": "this contains cells text"},
        \\  "cells": [],
        \\  "nbformat": 4
        \\}
    ;
    const cell = "{\"cell_type\":\"code\",\"metadata\":{},\"source\":[\"print(1)\"]}";
    const result = try appendNotebookCell(alloc, notebook, cell);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "print(1)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "this contains cells text") != null);
}

test "EditMode.parse accepts reference keywords and synonyms" {
    try testing.expectEqual(EditMode.append, EditMode.parse(null));
    try testing.expectEqual(EditMode.append, EditMode.parse(""));
    try testing.expectEqual(EditMode.append, EditMode.parse("append"));
    try testing.expectEqual(EditMode.append, EditMode.parse("add"));
    try testing.expectEqual(EditMode.replace, EditMode.parse("replace"));
    try testing.expectEqual(EditMode.replace, EditMode.parse("REPLACE"));
    try testing.expectEqual(EditMode.insert, EditMode.parse("insert"));
    try testing.expectEqual(EditMode.delete, EditMode.parse("delete"));
    try testing.expectEqual(EditMode.delete, EditMode.parse("remove"));
    try testing.expectEqual(EditMode.append, EditMode.parse("bogus-mode"));
}

test "applyIndexedEdit replace overwrites the target cell" {
    const alloc = testing.allocator;
    const notebook =
        \\{
        \\  "cells": [
        \\    {"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":["print(1)"]},
        \\    {"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":["print(2)"]}
        \\  ],
        \\  "metadata": {},
        \\  "nbformat": 4,
        \\  "nbformat_minor": 5
        \\}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "print('replaced')", "code", 0, .replace);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "replaced") != null);
    try testing.expect(std.mem.indexOf(u8, result, "print(2)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "print(1)") == null);
}

test "applyIndexedEdit insert splices a new cell at the index" {
    const alloc = testing.allocator;
    const notebook =
        \\{
        \\  "cells": [
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["A"]},
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["B"]}
        \\  ],
        \\  "metadata": {},
        \\  "nbformat": 4,
        \\  "nbformat_minor": 5
        \\}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "MIDDLE", "code", 1, .insert);
    defer alloc.free(result);
    const a_idx = std.mem.indexOf(u8, result, "\"A\"") orelse return error.MissingA;
    const mid_idx = std.mem.indexOf(u8, result, "MIDDLE") orelse return error.MissingMiddle;
    const b_idx = std.mem.indexOf(u8, result, "\"B\"") orelse return error.MissingB;
    try testing.expect(a_idx < mid_idx);
    try testing.expect(mid_idx < b_idx);
}

test "applyIndexedEdit insert at the end appends" {
    const alloc = testing.allocator;
    const notebook =
        \\{
        \\  "cells": [
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["A"]}
        \\  ],
        \\  "metadata": {},
        \\  "nbformat": 4
        \\}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "NEW", "code", 1, .insert);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "\"A\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "NEW") != null);
}

test "applyIndexedEdit delete drops the target cell" {
    const alloc = testing.allocator;
    const notebook =
        \\{
        \\  "cells": [
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["keep_1"]},
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["drop_me"]},
        \\    {"cell_type":"code","metadata":{},"outputs":[],"source":["keep_2"]}
        \\  ],
        \\  "metadata": {},
        \\  "nbformat": 4
        \\}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "", "code", 1, .delete);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "keep_1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "keep_2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "drop_me") == null);
}

test "applyIndexedEdit rejects out-of-range replace" {
    const alloc = testing.allocator;
    const notebook =
        \\{"cells":[{"cell_type":"code","metadata":{},"outputs":[],"source":["x"]}],"metadata":{},"nbformat":4}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "new", "code", 5, .replace);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "out of range") != null);
}

test "applyIndexedEdit rejects out-of-range delete on empty notebook" {
    const alloc = testing.allocator;
    const notebook =
        \\{"cells":[],"metadata":{},"nbformat":4}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "", "code", 0, .delete);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "out of range") != null);
}

test "applyIndexedEdit insert accepts index 0 on an empty notebook" {
    const alloc = testing.allocator;
    const notebook =
        \\{"cells":[],"metadata":{},"nbformat":4}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "first", "code", 0, .insert);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "first") != null);
}

test "applyIndexedEdit handles markdown cell type" {
    const alloc = testing.allocator;
    const notebook =
        \\{"cells":[],"metadata":{},"nbformat":4}
    ;
    const result = try applyIndexedEdit(alloc, notebook, "# Title", "markdown", 0, .insert);
    defer alloc.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "markdown") != null);
    try testing.expect(std.mem.indexOf(u8, result, "# Title") != null);
}
