const std = @import("std");
const std_io = @import("../core/std_io.zig");
const repl_input = @import("repl_input.zig");
const repl_attachments = @import("repl_attachments.zig");

// Upper bound on a vim count prefix, matching the reference's MAX_VIM_COUNT
// (src/vim/types.ts). The clamp is applied after each multiply-add so a count
// can never exceed this value.
const MAX_VIM_COUNT: usize = 10000;

pub const Mode = enum {
    insert,
    normal,
};

const Pending = enum {
    none,
    delete,
    change,
    yank,
    replace,
    g,
    indent,
    dedent,
};

const FindType = enum {
    forward,
    backward,
    until_forward,
    until_backward,
};

const TextObjectScope = enum {
    inner,
    around,
};

const IndentDir = enum {
    in,
    out,
};

const RecordedChange = union(enum) {
    none,
    insert,
    x: usize,
    replace: struct {
        ch: u8,
        count: usize,
    },
    paste: struct {
        before: bool,
        count: usize,
    },
    open_line: struct {
        before: bool,
    },
    delete_to_line_end: struct {
        enter_insert: bool,
    },
    substitute: usize,
    toggle_case: usize,
    join: usize,
    indent: struct {
        dir: IndentDir,
        count: usize,
    },
    linewise_operator: struct {
        op: Pending,
        count: usize,
    },
    // operator+G (to_first = false) and operator+gg (to_first = true): a
    // linewise operation spanning the cursor line and the target line (last
    // line, first line, or line N when count != 1).
    operator_g: struct {
        op: Pending,
        to_first: bool,
        count: usize,
    },
    operator: struct {
        op: Pending,
        motion: u8,
        count: usize,
    },
    operator_find: struct {
        op: Pending,
        find: FindType,
        ch: u8,
        count: usize,
    },
    operator_textobj: struct {
        op: Pending,
        scope: TextObjectScope,
        obj: u8,
        count: usize,
    },
};

const LastFind = struct {
    find: FindType,
    ch: u8,
};

const Range = struct {
    start: usize,
    end: usize,
};

pub const HandleResult = struct {
    handled: bool = false,
    modified: bool = false,
    enter_insert: bool = false,
    request_undo: bool = false,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    enabled: bool = false,
    mode: Mode = .insert,
    pending: Pending = .none,
    count: usize = 0,
    operator_motion_count: usize = 0,
    pending_replace_count: usize = 1,
    pending_find: ?FindType = null,
    pending_find_count: usize = 1,
    pending_textobj_scope: ?TextObjectScope = null,
    pending_textobj_count: usize = 1,
    // Operator+g two-step (dgg/cgg/ygg): set to the operator when an operator is
    // pending and 'g' arrives, so the next 'g' resolves to "operate linewise to
    // the first line (or line N with count)". Distinct from the standalone
    // pending == .g path so the two cannot collide.
    pending_g_operator: ?Pending = null,
    pending_g_operator_count: usize = 1,
    register: std_io.StringBuilder,
    register_linewise: bool = false,
    last_find: ?LastFind = null,
    last_change: RecordedChange = .none,
    insert_base: std_io.StringBuilder,
    insert_base_cursor: usize = 0,
    last_inserted: std_io.StringBuilder,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .allocator = allocator,
            .register = std_io.StringBuilder.init(allocator),
            .insert_base = std_io.StringBuilder.init(allocator),
            .last_inserted = std_io.StringBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        self.register.deinit();
        self.insert_base.deinit();
        self.last_inserted.deinit();
    }

    pub fn setEnabled(self: *State, enabled: bool) void {
        self.enabled = enabled;
        self.mode = .insert;
        self.clearPending();
        self.insert_base.clearRetainingCapacity();
        self.insert_base_cursor = 0;
    }

    pub fn beginInsertSession(self: *State, text: []const u8, cursor: usize) !void {
        if (!self.enabled) return;
        self.insert_base.clearRetainingCapacity();
        try self.insert_base.appendSlice(text);
        self.insert_base_cursor = @min(cursor, text.len);
    }

    pub fn enterNormal(self: *State, text: []const u8, cursor: *usize) !void {
        if (self.mode == .insert) {
            try self.finishInsertSession(text, cursor.*);
        }
        self.mode = .normal;
        self.clearPending();
        if (text.len == 0) {
            cursor.* = 0;
            return;
        }
        if (cursor.* > 0) cursor.* -= 1;
        if (cursor.* >= text.len) cursor.* = text.len - 1;
        cursor.* = normalizeAttachmentCursor(text, cursor.*);
    }

    pub fn enterInsert(self: *State, text: []const u8, cursor: usize) !void {
        self.mode = .insert;
        self.clearPending();
        try self.beginInsertSession(text, cursor);
    }

    pub fn clearPending(self: *State) void {
        self.pending = .none;
        self.count = 0;
        self.operator_motion_count = 0;
        self.pending_replace_count = 1;
        self.pending_find = null;
        self.pending_find_count = 1;
        self.pending_textobj_scope = null;
        self.pending_textobj_count = 1;
        self.pending_g_operator = null;
        self.pending_g_operator_count = 1;
    }

    pub fn footerLabel(self: *const State) []const u8 {
        if (!self.enabled) return "";
        return switch (self.mode) {
            .insert => "VIM INSERT",
            .normal => "VIM NORMAL",
        };
    }

    pub fn handleNormalKey(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        key: u8,
    ) !HandleResult {
        if (!self.enabled or self.mode != .normal) return .{};
        if (key < 0x20 or key > 0x7e) return .{ .handled = true };

        if (self.pending == .replace) {
            const replace_count = self.pending_replace_count;
            self.pending = .none;
            self.pending_replace_count = 1;
            self.count = 0;
            return try self.handleReplace(input_buf, cursor, key, replace_count, true);
        }

        if (self.pending_find) |find| {
            const find_count = self.pending_find_count;
            self.pending_find = null;
            self.pending_find_count = 1;
            return try self.handleFindKey(input_buf, cursor, key, find, find_count, true);
        }

        if (self.pending_textobj_scope) |scope| {
            const textobj_count = self.pending_textobj_count;
            self.pending_textobj_scope = null;
            self.pending_textobj_count = 1;
            return try self.handleOperatorTextObject(input_buf, cursor, scope, key, textobj_count, true);
        }

        // Operator+g waiting for the second g (dgg/cgg/ygg). Any key other than
        // 'g' clears pending without modifying, matching vim's doubled-key rule.
        if (self.pending_g_operator) |op| {
            const count = self.pending_g_operator_count;
            self.pending_g_operator = null;
            self.pending_g_operator_count = 1;
            self.pending = .none;
            if (key == 'g') {
                return try self.applyRecordedOperatorG(input_buf, cursor, op, true, count, true);
            }
            return .{ .handled = true };
        }

        if (self.pending == .g) {
            const count = self.consumeCount();
            self.pending = .none;
            switch (key) {
                // gg jumps to the first line (or line N with a count).
                'g' => cursor.* = moveToFirstLine(input_buf.items(), count),
                // gj/gk are display-line motions. Our REPL renderer does not
                // soft-wrap distinctly, so a display line equals a logical line
                // here; treat them as plain j/k rather than dropping the keys.
                'j' => cursor.* = moveVertical(input_buf.items(), cursor.*, count, true),
                'k' => cursor.* = moveVertical(input_buf.items(), cursor.*, count, false),
                else => {},
            }
            return .{ .handled = true };
        }

        // Indent/dedent require the key to be doubled (>> / <<). Any other
        // second key clears pending without modifying, matching vim's behavior
        // (reference transitions.ts fromIndent: only input === state.dir runs).
        if (self.pending == .indent or self.pending == .dedent) {
            const dir: IndentDir = if (self.pending == .indent) .in else .out;
            const expected: u8 = if (self.pending == .indent) '>' else '<';
            const count = self.consumeCount();
            self.pending = .none;
            if (key == expected) {
                return try self.applyIndent(input_buf, cursor, dir, count, true);
            }
            return .{ .handled = true };
        }

        switch (self.pending) {
            .delete, .change, .yank => return try self.handleOperatorKey(input_buf, cursor, key, true),
            else => {},
        }

        if (key >= '1' and key <= '9') {
            self.pushCountDigit(key);
            return .{ .handled = true };
        }

        switch (key) {
            '0' => {
                if (self.count > 0) {
                    self.pushCountDigit(key);
                } else {
                    cursor.* = lineStart(input_buf.items(), cursor.*);
                }
            },
            'h' => cursor.* = moveLeft(input_buf.items(), cursor.*, self.consumeCount()),
            'l' => cursor.* = moveRight(input_buf.items(), cursor.*, self.consumeCount()),
            'w' => cursor.* = moveWordForward(input_buf.items(), cursor.*, self.consumeCount()),
            'b' => cursor.* = moveWordBackward(input_buf.items(), cursor.*, self.consumeCount()),
            'e' => cursor.* = moveWordEnd(input_buf.items(), cursor.*, self.consumeCount()),
            'W' => cursor.* = moveBigWordForward(input_buf.items(), cursor.*, self.consumeCount()),
            'B' => cursor.* = moveBigWordBackward(input_buf.items(), cursor.*, self.consumeCount()),
            'E' => cursor.* = moveBigWordEnd(input_buf.items(), cursor.*, self.consumeCount()),
            'j' => cursor.* = moveVertical(input_buf.items(), cursor.*, self.consumeCount(), true),
            'k' => cursor.* = moveVertical(input_buf.items(), cursor.*, self.consumeCount(), false),
            '^' => cursor.* = firstNonBlank(input_buf.items(), cursor.*),
            '$' => cursor.* = lineLastChar(input_buf.items(), cursor.*),
            'g' => self.pending = .g,
            'G' => cursor.* = moveToLastLine(input_buf.items(), self.consumeCount()),
            'f', 'F', 't', 'T' => {
                self.pending_find = parseFindType(key);
                self.pending_find_count = self.consumeCount();
                return .{ .handled = true };
            },
            ';' => return try self.repeatLastFind(input_buf, cursor, false),
            ',' => return try self.repeatLastFind(input_buf, cursor, true),
            '.' => return try self.repeatLastChange(input_buf, cursor),
            'i' => return .{ .handled = true, .enter_insert = true },
            'a' => {
                cursor.* = insertAfterCursor(input_buf.items(), cursor.*);
                return .{ .handled = true, .enter_insert = true };
            },
            'I' => {
                cursor.* = firstNonBlank(input_buf.items(), cursor.*);
                return .{ .handled = true, .enter_insert = true };
            },
            'A' => {
                cursor.* = lineEndExclusive(input_buf.items(), cursor.*);
                return .{ .handled = true, .enter_insert = true };
            },
            'o' => return try self.openLine(input_buf, cursor, false, true),
            'O' => return try self.openLine(input_buf, cursor, true, true),
            'x' => return try self.deleteChars(input_buf, cursor, self.consumeCount(), true),
            'D' => return try self.deleteToLineEnd(input_buf, cursor, false, true),
            'C' => return try self.deleteToLineEnd(input_buf, cursor, true, true),
            's' => return try self.substituteChars(input_buf, cursor, self.consumeCount(), true),
            '~' => return try self.toggleCase(input_buf, cursor, self.consumeCount(), true),
            'J' => return try self.joinLines(input_buf, cursor, self.consumeCount(), true),
            'Y' => return try self.handleLinewiseOperator(.yank, input_buf, cursor, self.consumeCount(), false),
            'p' => return try self.paste(input_buf, cursor, false, self.consumeCount(), true),
            'P' => return try self.paste(input_buf, cursor, true, self.consumeCount(), true),
            'u' => {
                self.clearPending();
                return .{ .handled = true, .request_undo = true };
            },
            'r' => {
                self.pending = .replace;
                self.pending_replace_count = self.consumeCount();
                return .{ .handled = true };
            },
            'd' => {
                self.pending = .delete;
                return .{ .handled = true };
            },
            'c' => {
                self.pending = .change;
                return .{ .handled = true };
            },
            'y' => {
                self.pending = .yank;
                return .{ .handled = true };
            },
            '>' => {
                self.count = self.consumeCount();
                self.pending = .indent;
                return .{ .handled = true };
            },
            '<' => {
                self.count = self.consumeCount();
                self.pending = .dedent;
                return .{ .handled = true };
            },
            else => self.clearPending(),
        }

        return .{ .handled = true };
    }

    fn finishInsertSession(self: *State, text: []const u8, cursor: usize) !void {
        if (!self.enabled) return;
        if (extractInsertedText(self.insert_base.items(), self.insert_base_cursor, text, cursor)) |inserted| {
            if (inserted.len > 0) {
                self.last_inserted.clearRetainingCapacity();
                try self.last_inserted.appendSlice(inserted);
                self.last_change = .insert;
            }
        }
    }

    fn repeatLastChange(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
    ) !HandleResult {
        return switch (self.last_change) {
            .none => .{ .handled = true },
            .insert => blk: {
                if (self.last_inserted.items().len == 0) break :blk .{ .handled = true };
                var write_cursor = @min(cursor.*, input_buf.items().len);
                try repl_input.insertInputBytesAt(input_buf, &write_cursor, self.last_inserted.items());
                cursor.* = if (write_cursor == 0) 0 else write_cursor - 1;
                break :blk .{ .handled = true, .modified = true };
            },
            .x => |count| try self.deleteChars(input_buf, cursor, count, false),
            .replace => |change| try self.handleReplace(input_buf, cursor, change.ch, change.count, false),
            .paste => |change| try self.paste(input_buf, cursor, change.before, change.count, false),
            .open_line => |change| try self.openLine(input_buf, cursor, change.before, false),
            .delete_to_line_end => |change| try self.deleteToLineEnd(input_buf, cursor, change.enter_insert, false),
            .substitute => |count| try self.substituteChars(input_buf, cursor, count, false),
            .toggle_case => |count| try self.toggleCase(input_buf, cursor, count, false),
            .join => |count| try self.joinLines(input_buf, cursor, count, false),
            .indent => |change| try self.applyIndent(input_buf, cursor, change.dir, change.count, false),
            .linewise_operator => |change| try self.handleLinewiseOperator(change.op, input_buf, cursor, change.count, false),
            .operator_g => |change| try self.applyRecordedOperatorG(input_buf, cursor, change.op, change.to_first, change.count, false),
            .operator => |change| try self.applyRecordedOperatorMotion(input_buf, cursor, change.op, change.motion, change.count, false),
            .operator_find => |change| try self.applyRecordedOperatorFind(input_buf, cursor, change.op, change.find, change.ch, change.count, false),
            .operator_textobj => |change| try self.applyRecordedOperatorTextObject(input_buf, cursor, change.op, change.scope, change.obj, change.count, false),
        };
    }

    fn repeatLastFind(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        reverse: bool,
    ) !HandleResult {
        const last = self.last_find orelse return .{ .handled = true };
        const effective = if (reverse) reverseFindType(last.find) else last.find;
        const count = self.consumeCount();
        return try self.applyFindMotion(input_buf, cursor, last.ch, effective, count, false);
    }

    fn handleFindKey(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        key: u8,
        find: FindType,
        count: usize,
        record: bool,
    ) !HandleResult {
        switch (self.pending) {
            .delete, .change, .yank => {
                const op = self.pending;
                self.pending = .none;
                return try self.applyRecordedOperatorFind(input_buf, cursor, op, find, key, count, record);
            },
            else => return try self.applyFindMotion(input_buf, cursor, key, find, count, record),
        }
    }

    fn applyFindMotion(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        needle: u8,
        find: FindType,
        count: usize,
        record: bool,
    ) !HandleResult {
        _ = record;
        if (input_buf.items().len == 0 or cursor.* >= input_buf.items().len) {
            return .{ .handled = true };
        }
        const target = findCharacterTarget(input_buf.items(), cursor.*, needle, count, find) orelse return .{ .handled = true };
        cursor.* = target;
        self.last_find = .{ .find = find, .ch = needle };
        return .{ .handled = true };
    }

    fn applyRecordedOperatorFind(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        op: Pending,
        find: FindType,
        needle: u8,
        count: usize,
        record: bool,
    ) !HandleResult {
        if (input_buf.items().len == 0 or cursor.* >= input_buf.items().len) {
            return .{ .handled = true, .enter_insert = op == .change };
        }
        const target = findCharacterTarget(input_buf.items(), cursor.*, needle, count, find) orelse return .{ .handled = true };
        const start = if (target < cursor.*) target else cursor.*;
        const end = if (target < cursor.*) @min(cursor.* + 1, input_buf.items().len) else @min(target + 1, input_buf.items().len);
        self.last_find = .{ .find = find, .ch = needle };
        const result = try self.applyOperatorRange(op, input_buf, cursor, start, end);
        if (record and op != .yank and (result.modified or result.enter_insert)) {
            self.last_change = .{ .operator_find = .{
                .op = op,
                .find = find,
                .ch = needle,
                .count = count,
            } };
        }
        return result;
    }

    fn handleReplace(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        key: u8,
        count: usize,
        record: bool,
    ) !HandleResult {
        if (input_buf.items().len == 0 or cursor.* >= input_buf.items().len) {
            return .{ .handled = true };
        }

        const start = normalizeAttachmentCursor(input_buf.items(), cursor.*);
        const replace_range = logicalForwardRange(input_buf.items(), start, count);
        const changed = try self.deleteRange(input_buf, cursor, start, replace_range.end, false);
        if (replace_range.units > 0) {
            var repeated = std_io.StringBuilder.init(self.allocator);
            defer repeated.deinit();
            var i: usize = 0;
            while (i < replace_range.units) : (i += 1) {
                try repeated.append(key);
            }
            var write_cursor = @min(start, input_buf.items().len);
            try repl_input.insertInputBytesAt(input_buf, &write_cursor, repeated.items());
            cursor.* = if (write_cursor == 0) 0 else write_cursor - 1;
        }
        if (record) {
            self.last_change = .{ .replace = .{ .ch = key, .count = count } };
        }
        return .{ .handled = true, .modified = changed or replace_range.units > 0 };
    }

    fn handleOperatorKey(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        key: u8,
        record: bool,
    ) !HandleResult {
        const op = self.pending;

        if ((key >= '1' and key <= '9') or (key == '0' and self.operator_motion_count > 0)) {
            self.pushOperatorCountDigit(key);
            return .{ .handled = true };
        }

        const count = self.consumeOperatorCount();
        self.pending = .none;

        if ((op == .delete and key == 'd') or
            (op == .change and key == 'c') or
            (op == .yank and key == 'y'))
        {
            return try self.handleLinewiseOperator(op, input_buf, cursor, count, record);
        }

        const text = input_buf.items();
        if (text.len == 0 and op != .yank) {
            return .{ .handled = true, .enter_insert = op == .change };
        }

        switch (key) {
            // Charwise motions (h/l/b) and linewise motions (j/k) join the
            // existing word/line operator motions. j/k are linewise inside an
            // operator (dj deletes whole lines) even though they are charwise as
            // standalone motions; applyRecordedOperatorMotion keeps them distinct.
            'w', 'e', 'W', 'E', 'B', '$', '0', '^', 'h', 'l', 'b', 'j', 'k' => return try self.applyRecordedOperatorMotion(input_buf, cursor, op, key, count, record),
            // operator+G operates linewise from the cursor line down to the last
            // line (or line N when a count is given).
            'G' => return try self.applyRecordedOperatorG(input_buf, cursor, op, false, count, record),
            // operator+g sets a sub-state; the next 'g' resolves to operator+gg
            // (operate linewise up to the first line / line N).
            'g' => {
                self.pending_g_operator = op;
                self.pending_g_operator_count = count;
                return .{ .handled = true };
            },
            'f', 'F', 't', 'T' => {
                self.pending = op;
                self.pending_find = parseFindType(key);
                self.pending_find_count = count;
                return .{ .handled = true };
            },
            'i' => {
                self.pending = op;
                self.pending_textobj_scope = .inner;
                self.pending_textobj_count = count;
                return .{ .handled = true };
            },
            'a' => {
                self.pending = op;
                self.pending_textobj_scope = .around;
                self.pending_textobj_count = count;
                return .{ .handled = true };
            },
            else => return .{ .handled = true },
        }
    }

    fn handleLinewiseOperator(
        self: *State,
        op: Pending,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        count: usize,
        record: bool,
    ) !HandleResult {
        const range = lineRangeForCount(input_buf.items(), cursor.*, count);
        var result = HandleResult{ .handled = true };
        switch (op) {
            .delete => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                result.modified = changed;
            },
            .change => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                cursor.* = @min(range.start, input_buf.items().len);
                result.modified = changed;
                result.enter_insert = true;
            },
            .yank => {
                try self.yankRange(input_buf.items(), range.start, range.end, true);
                cursor.* = @min(range.start, if (input_buf.items().len == 0) 0 else input_buf.items().len - 1);
            },
            else => {},
        }
        if (record and op != .yank and (result.modified or result.enter_insert)) {
            self.last_change = .{ .linewise_operator = .{ .op = op, .count = count } };
        }
        return result;
    }

    fn applyRecordedOperatorMotion(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        op: Pending,
        motion: u8,
        count: usize,
        record: bool,
    ) !HandleResult {
        const text = input_buf.items();
        if (text.len == 0 and op != .yank) {
            return .{ .handled = true, .enter_insert = op == .change };
        }

        const result = switch (motion) {
            // cw is special-cased to ce: changing a word stops at the word END
            // (excluding trailing whitespace) rather than the next word start,
            // matching vim and operators.ts:441-450. delete/yank keep the
            // exclusive next-word-start range (dw consumes trailing whitespace).
            'w' => if (op == .change) blk: {
                const end = moveWordEnd(text, cursor.*, count);
                break :blk try self.applyOperatorRange(op, input_buf, cursor, cursor.*, if (text.len == 0) 0 else @min(end + 1, text.len));
            } else try self.applyOperatorRange(op, input_buf, cursor, cursor.*, wordForwardExclusive(text, cursor.*, count)),
            'e' => blk: {
                const end = moveWordEnd(text, cursor.*, count);
                break :blk try self.applyOperatorRange(op, input_buf, cursor, cursor.*, if (text.len == 0) 0 else @min(end + 1, text.len));
            },
            // cW is special-cased to cE for the same reason (WORD end vs next
            // WORD start). dW/yW keep the exclusive next-WORD-start range.
            'W' => if (op == .change) blk: {
                const end = moveBigWordEnd(text, cursor.*, count);
                break :blk try self.applyOperatorRange(op, input_buf, cursor, cursor.*, if (text.len == 0) 0 else @min(end + 1, text.len));
            } else try self.applyOperatorRange(op, input_buf, cursor, cursor.*, bigWordForwardExclusive(text, cursor.*, count)),
            'E' => blk: {
                const end = moveBigWordEnd(text, cursor.*, count);
                break :blk try self.applyOperatorRange(op, input_buf, cursor, cursor.*, if (text.len == 0) 0 else @min(end + 1, text.len));
            },
            'B' => try self.applyOperatorRange(op, input_buf, cursor, moveBigWordBackward(text, cursor.*, count), cursor.*),
            // Charwise back to the previous word start (db deletes the previous word).
            'b' => try self.applyOperatorRange(op, input_buf, cursor, moveWordBackward(text, cursor.*, count), cursor.*),
            // h: charwise left count chars, clamped at the line start.
            'h' => try self.applyOperatorRange(op, input_buf, cursor, charwiseLeftClamped(text, cursor.*, count), cursor.*),
            // l: charwise right count chars (inclusive of the cursor char),
            // clamped at the line end.
            'l' => try self.applyOperatorRange(op, input_buf, cursor, cursor.*, charwiseRightClamped(text, cursor.*, count)),
            // j/k are LINEWISE inside an operator: dj deletes the current line
            // plus count lines below; dk deletes the current line plus count
            // lines above. The span is computed between the cursor and the
            // vertically-moved position so count+1 logical lines are operated on.
            'j' => try self.applyLinewiseRange(op, input_buf, cursor, linewiseRangeBetween(text, cursor.*, moveVertical(text, cursor.*, count, true))),
            'k' => try self.applyLinewiseRange(op, input_buf, cursor, linewiseRangeBetween(text, cursor.*, moveVertical(text, cursor.*, count, false))),
            '$' => try self.applyOperatorRange(op, input_buf, cursor, cursor.*, lineEndExclusive(text, cursor.*)),
            '0' => try self.applyOperatorRange(op, input_buf, cursor, lineStart(text, cursor.*), if (text.len == 0) 0 else @min(cursor.* + 1, text.len)),
            '^' => try self.applyOperatorRange(op, input_buf, cursor, firstNonBlank(text, cursor.*), if (text.len == 0) 0 else @min(cursor.* + 1, text.len)),
            else => HandleResult{ .handled = true },
        };

        if (record and op != .yank and (result.modified or result.enter_insert)) {
            self.last_change = .{ .operator = .{
                .op = op,
                .motion = motion,
                .count = count,
            } };
        }
        return result;
    }

    fn applyRecordedOperatorG(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        op: Pending,
        to_first: bool,
        count: usize,
        record: bool,
    ) !HandleResult {
        // operator+G / operator+gg: a linewise operation spanning the cursor's
        // line and the target line. Mirrors executeOperatorG/Gg (operators.ts:
        // 524-556). count == 1 means no explicit count, so the target is the
        // last (G) or first (gg) line; otherwise the target is line N.
        const text = input_buf.items();
        if (text.len == 0 and op != .yank) {
            return .{ .handled = true, .enter_insert = op == .change };
        }

        const target = if (to_first)
            // gg: line N when a count is given, else the first line.
            moveToFirstLine(text, count)
        else
            // G: line N when a count is given, else the last line.
            moveToLastLine(text, count);

        const range = linewiseRangeBetween(text, cursor.*, target);
        var result = HandleResult{ .handled = true };
        switch (op) {
            .delete => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                result.modified = changed;
            },
            .change => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                cursor.* = @min(range.start, input_buf.items().len);
                result.modified = changed;
                result.enter_insert = true;
            },
            .yank => {
                try self.yankRange(input_buf.items(), range.start, range.end, true);
                cursor.* = @min(range.start, if (input_buf.items().len == 0) 0 else input_buf.items().len - 1);
            },
            else => {},
        }

        if (record and op != .yank and (result.modified or result.enter_insert)) {
            self.last_change = .{ .operator_g = .{
                .op = op,
                .to_first = to_first,
                .count = count,
            } };
        }
        return result;
    }

    fn handleOperatorTextObject(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        scope: TextObjectScope,
        obj_type: u8,
        count: usize,
        record: bool,
    ) !HandleResult {
        const op = self.pending;
        self.pending = .none;
        return try self.applyRecordedOperatorTextObject(input_buf, cursor, op, scope, obj_type, count, record);
    }

    fn applyRecordedOperatorTextObject(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        op: Pending,
        scope: TextObjectScope,
        obj_type: u8,
        count: usize,
        record: bool,
    ) !HandleResult {
        const range = findTextObjectRange(input_buf.items(), cursor.*, obj_type, scope) orelse return .{ .handled = true };
        const result = try self.applyOperatorRange(op, input_buf, cursor, range.start, range.end);
        if (record and op != .yank and (result.modified or result.enter_insert)) {
            self.last_change = .{ .operator_textobj = .{
                .op = op,
                .scope = scope,
                .obj = obj_type,
                .count = count,
            } };
        }
        return result;
    }

    fn applyOperatorRange(
        self: *State,
        op: Pending,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        start_raw: usize,
        end_raw: usize,
    ) !HandleResult {
        var start = start_raw;
        var end = end_raw;
        if (end < start) std.mem.swap(usize, &start, &end);
        if (start == end) return .{ .handled = true, .enter_insert = op == .change and input_buf.items().len == 0 };

        switch (op) {
            .delete => {
                const changed = try self.deleteRange(input_buf, cursor, start, end, false);
                return .{ .handled = true, .modified = changed };
            },
            .change => {
                const changed = try self.deleteRange(input_buf, cursor, start, end, false);
                cursor.* = @min(start, input_buf.items().len);
                return .{ .handled = true, .modified = changed, .enter_insert = true };
            },
            .yank => {
                try self.yankRange(input_buf.items(), start, end, false);
                cursor.* = @min(start, if (input_buf.items().len == 0) 0 else input_buf.items().len - 1);
                return .{ .handled = true };
            },
            else => return .{ .handled = true },
        }
    }

    // Apply a linewise operator (delete/change/yank) over an already-computed
    // linewise range. Mirrors handleLinewiseOperator / applyRecordedOperatorG so
    // operator+j/k (and any future linewise motion) place the cursor and set the
    // linewise register the same way yy/dd do.
    fn applyLinewiseRange(
        self: *State,
        op: Pending,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        range: Range,
    ) !HandleResult {
        var result = HandleResult{ .handled = true };
        switch (op) {
            .delete => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                result.modified = changed;
            },
            .change => {
                const changed = try self.deleteRange(input_buf, cursor, range.start, range.end, true);
                cursor.* = @min(range.start, input_buf.items().len);
                result.modified = changed;
                result.enter_insert = true;
            },
            .yank => {
                try self.yankRange(input_buf.items(), range.start, range.end, true);
                cursor.* = @min(range.start, if (input_buf.items().len == 0) 0 else input_buf.items().len - 1);
            },
            else => {},
        }
        return result;
    }

    fn openLine(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        before: bool,
        record: bool,
    ) !HandleResult {
        var insert_at = if (before)
            lineStart(input_buf.items(), cursor.*)
        else blk: {
            const end = lineEndExclusive(input_buf.items(), cursor.*);
            if (end < input_buf.items().len and input_buf.items()[end] == '\n') break :blk end + 1;
            break :blk input_buf.items().len;
        };
        try repl_input.insertInputBytesAt(input_buf, &insert_at, "\n");
        cursor.* = insert_at;
        if (record) {
            self.last_change = .{ .open_line = .{ .before = before } };
        }
        return .{ .handled = true, .modified = true, .enter_insert = true };
    }

    fn deleteChars(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        count: usize,
        record: bool,
    ) !HandleResult {
        if (input_buf.items().len == 0 or cursor.* >= input_buf.items().len) return .{ .handled = true };
        const start = normalizeAttachmentCursor(input_buf.items(), cursor.*);
        const end = logicalForwardRange(input_buf.items(), start, count).end;
        const changed = try self.deleteRange(input_buf, cursor, start, end, false);
        if (record and changed) {
            self.last_change = .{ .x = count };
        }
        return .{ .handled = true, .modified = changed };
    }

    fn deleteToLineEnd(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        enter_insert: bool,
        record: bool,
    ) !HandleResult {
        const start = if (input_buf.items().len == 0) 0 else normalizeAttachmentCursor(input_buf.items(), cursor.*);
        const end = lineEndExclusive(input_buf.items(), start);
        const changed = try self.deleteRange(input_buf, cursor, start, end, false);
        if (enter_insert) {
            cursor.* = @min(cursor.*, input_buf.items().len);
        }
        if (record and (changed or enter_insert)) {
            self.last_change = .{ .delete_to_line_end = .{ .enter_insert = enter_insert } };
        }
        return .{ .handled = true, .modified = changed, .enter_insert = enter_insert };
    }

    fn substituteChars(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        count: usize,
        record: bool,
    ) !HandleResult {
        if (input_buf.items().len == 0) {
            if (record) self.last_change = .{ .substitute = count };
            return .{ .handled = true, .enter_insert = true };
        }
        const start = normalizeAttachmentCursor(input_buf.items(), cursor.*);
        const end = logicalForwardRange(input_buf.items(), start, count).end;
        const changed = try self.deleteRange(input_buf, cursor, start, end, false);
        cursor.* = @min(cursor.*, input_buf.items().len);
        if (record) {
            self.last_change = .{ .substitute = count };
        }
        return .{ .handled = true, .modified = changed, .enter_insert = true };
    }

    fn toggleCase(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        count: usize,
        record: bool,
    ) !HandleResult {
        // The reference toggles graphemes; we operate on ASCII bytes to stay
        // consistent with the rest of repl_vim.zig's byte-cursor model.
        // Non-ASCII bytes pass through unchanged.
        const text = input_buf.items();
        if (text.len == 0 or cursor.* >= text.len) {
            if (record) self.last_change = .{ .toggle_case = count };
            return .{ .handled = true };
        }
        const start = @min(cursor.*, text.len);
        // Do not cross the line boundary, matching vim's per-line ~ behavior.
        const line_end = lineEndExclusive(text, start);
        var i = start;
        var remaining = count;
        var changed = false;
        while (remaining > 0 and i < line_end) : (remaining -= 1) {
            const b = text[i];
            if (std.ascii.isUpper(b)) {
                text[i] = std.ascii.toLower(b);
                changed = true;
            } else if (std.ascii.isLower(b)) {
                text[i] = std.ascii.toUpper(b);
                changed = true;
            }
            i += 1;
        }
        // Advance the cursor to just past the toggled run, but clamp to the last
        // char of the line (vim never lands on the trailing newline / past EOL).
        cursor.* = if (i < line_end) i else (if (i > start) i - 1 else start);
        if (record) {
            self.last_change = .{ .toggle_case = count };
        }
        return .{ .handled = true, .modified = changed };
    }

    fn joinLines(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        count: usize,
        record: bool,
    ) !HandleResult {
        // Mirror the reference executeJoin (operators.ts:258-289): join the
        // current line with up to `count` following lines, trimming each next
        // line's leading whitespace and separating with a single space (unless
        // the running line is empty or already ends with a space). The cursor
        // lands at the join seam (the original end of the current line).
        const text = input_buf.items();
        const ls = lineStart(text, cursor.*);
        var le = lineEndExclusive(text, cursor.*);

        // No next line to join with: J on the last (or only) line is a no-op.
        if (le >= text.len) {
            if (record) self.last_change = .{ .join = count };
            return .{ .handled = true };
        }

        // The cursor seam is the position of the first joined space, i.e. just
        // past the current line's existing content.
        const seam = le - ls;

        var joined = std_io.StringBuilder.init(self.allocator);
        defer joined.deinit();
        try joined.appendSlice(text[ls..le]);

        var remaining = count;
        // Walk forward over following lines. `le` points at the '\n' that ends
        // the running region; advance past it to the next line's content.
        while (remaining > 0 and le < text.len and text[le] == '\n') : (remaining -= 1) {
            const next_start = le + 1;
            const next_end = lineEndExclusive(text, next_start);
            const next_line = std.mem.trimStart(u8, text[next_start..next_end], " \t");
            if (next_line.len > 0) {
                const cur = joined.items();
                if (cur.len > 0 and cur[cur.len - 1] != ' ') {
                    try joined.append(' ');
                }
                try joined.appendSlice(next_line);
            }
            le = next_end;
        }

        // Replace the whole joined region [ls, le) with the rebuilt line.
        try input_buf.replaceRange(ls, le - ls, joined.items());

        const new_len = input_buf.items().len;
        cursor.* = @min(ls + seam, if (new_len == 0) 0 else new_len - 1);
        if (record) self.last_change = .{ .join = count };
        return .{ .handled = true, .modified = true };
    }

    fn applyIndent(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        dir: IndentDir,
        count: usize,
        record: bool,
    ) !HandleResult {
        // Mirror the reference executeIndent (operators.ts:348-392): operate on
        // `count` lines starting at the cursor's line. Indent prepends two
        // spaces; dedent strips a two-space prefix, else one leading tab, else
        // as much leading whitespace as possible up to two characters. The
        // cursor lands at the first non-blank of the (still-current) line.
        const indent = "  "; // two spaces

        const text = input_buf.items();
        const region_start = lineStart(text, cursor.*);

        // Rebuild the affected region line-by-line into `rebuilt`, then splice
        // it back in a single replaceRange so we never hold a stale `text`
        // slice across a reallocation.
        var rebuilt = std_io.StringBuilder.init(self.allocator);
        defer rebuilt.deinit();

        var scan = region_start;
        var remaining = count;
        var changed = false;
        while (remaining > 0) : (remaining -= 1) {
            const line_end = lineEndExclusive(text, scan);
            const line = text[scan..line_end];

            switch (dir) {
                .in => {
                    try rebuilt.appendSlice(indent);
                    try rebuilt.appendSlice(line);
                    changed = true;
                },
                .out => {
                    if (std.mem.startsWith(u8, line, indent)) {
                        try rebuilt.appendSlice(line[indent.len..]);
                        changed = true;
                    } else if (line.len > 0 and line[0] == '\t') {
                        try rebuilt.appendSlice(line[1..]);
                        changed = true;
                    } else {
                        // Strip as much leading whitespace as possible, up to
                        // the indent length (two characters).
                        var removed: usize = 0;
                        var idx: usize = 0;
                        while (idx < line.len and removed < indent.len and (line[idx] == ' ' or line[idx] == '\t')) {
                            removed += 1;
                            idx += 1;
                        }
                        if (removed > 0) changed = true;
                        try rebuilt.appendSlice(line[idx..]);
                    }
                },
            }

            // Advance to the next line, preserving the separating newline.
            if (line_end < text.len and text[line_end] == '\n') {
                try rebuilt.append('\n');
                scan = line_end + 1;
                // Stop if we have consumed every line (no content after the
                // trailing newline counts as a line in vim's model).
                if (scan >= text.len) break;
            } else {
                scan = line_end;
                break;
            }
        }

        const region_len = scan - region_start;
        try input_buf.replaceRange(region_start, region_len, rebuilt.items());

        const new_text = input_buf.items();
        cursor.* = @min(firstNonBlank(new_text, region_start), if (new_text.len == 0) 0 else new_text.len - 1);

        if (record) {
            self.last_change = .{ .indent = .{ .dir = dir, .count = count } };
        }
        return .{ .handled = true, .modified = changed };
    }

    fn paste(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        before: bool,
        count: usize,
        record: bool,
    ) !HandleResult {
        if (self.register.items().len == 0) return .{ .handled = true };

        var repeated = std_io.StringBuilder.init(self.allocator);
        defer repeated.deinit();
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try repeated.appendSlice(self.register.items());
        }

        if (self.register_linewise) {
            const insert_at = if (before)
                lineStart(input_buf.items(), cursor.*)
            else blk: {
                const end = lineEndExclusive(input_buf.items(), cursor.*);
                if (end < input_buf.items().len and input_buf.items()[end] == '\n') break :blk end + 1;
                break :blk input_buf.items().len;
            };
            var write_cursor = insert_at;
            try repl_input.insertInputBytesAt(input_buf, &write_cursor, repeated.items());
            cursor.* = insert_at;
            if (record) {
                self.last_change = .{ .paste = .{ .before = before, .count = count } };
            }
            return .{ .handled = true, .modified = true };
        }

        const insert_at = if (before)
            @min(normalizeAttachmentCursor(input_buf.items(), cursor.*), input_buf.items().len)
        else if (input_buf.items().len == 0)
            0
        else
            insertAfterCursor(input_buf.items(), cursor.*);
        var write_cursor = insert_at;
        try repl_input.insertInputBytesAt(input_buf, &write_cursor, repeated.items());
        cursor.* = if (before)
            @min(insert_at, if (input_buf.items().len == 0) 0 else input_buf.items().len - 1)
        else if (write_cursor == 0)
            0
        else
            normalizeAttachmentCursor(input_buf.items(), write_cursor - 1);
        if (record) {
            self.last_change = .{ .paste = .{ .before = before, .count = count } };
        }
        return .{ .handled = true, .modified = true };
    }

    fn deleteRange(
        self: *State,
        input_buf: *std_io.StringBuilder,
        cursor: *usize,
        start: usize,
        end: usize,
        linewise: bool,
    ) !bool {
        if (start >= end or start > input_buf.items().len) return false;
        const clamped_end = @min(end, input_buf.items().len);
        if (clamped_end <= start) return false;

        if (linewise) {
            try self.setRegisterLinewise(input_buf.items()[start..clamped_end]);
        } else {
            try self.setRegisterCharwise(input_buf.items()[start..clamped_end]);
        }

        const remove_len = clamped_end - start;
        std.mem.copyForwards(u8, input_buf.items()[start .. input_buf.items().len - remove_len], input_buf.items()[clamped_end..]);
        input_buf.shrinkRetainingCapacity(input_buf.items().len - remove_len);

        if (linewise) {
            cursor.* = @min(lineStart(input_buf.items(), start), if (input_buf.items().len == 0) 0 else input_buf.items().len - 1);
        } else if (input_buf.items().len == 0) {
            cursor.* = 0;
        } else {
            cursor.* = @min(start, input_buf.items().len - 1);
        }
        return true;
    }

    fn yankRange(self: *State, text: []const u8, start: usize, end: usize, linewise: bool) !void {
        if (start >= end or start > text.len) return;
        const clamped_end = @min(end, text.len);
        if (linewise) {
            try self.setRegisterLinewise(text[start..clamped_end]);
        } else {
            try self.setRegisterCharwise(text[start..clamped_end]);
        }
    }

    fn setRegisterCharwise(self: *State, slice: []const u8) !void {
        self.register.clearRetainingCapacity();
        try self.register.appendSlice(slice);
        self.register_linewise = false;
    }

    fn setRegisterLinewise(self: *State, slice: []const u8) !void {
        var normalized = slice;
        if (normalized.len > 0 and normalized[0] == '\n') normalized = normalized[1..];
        self.register.clearRetainingCapacity();
        try self.register.appendSlice(normalized);
        if (self.register.items().len == 0 or self.register.items()[self.register.items().len - 1] != '\n') {
            try self.register.append('\n');
        }
        self.register_linewise = true;
    }

    fn consumeCount(self: *State) usize {
        const out = if (self.count == 0) 1 else self.count;
        self.count = 0;
        return out;
    }

    fn consumeOperatorCount(self: *State) usize {
        const prefix = if (self.count == 0) 1 else self.count;
        const motion = if (self.operator_motion_count == 0) 1 else self.operator_motion_count;
        self.count = 0;
        self.operator_motion_count = 0;
        return prefix * motion;
    }

    fn pushCountDigit(self: *State, key: u8) void {
        const digit = key - '0';
        const next = self.count * 10 + digit;
        self.count = if (next > MAX_VIM_COUNT) MAX_VIM_COUNT else next;
    }

    fn pushOperatorCountDigit(self: *State, key: u8) void {
        const digit = key - '0';
        const next = self.operator_motion_count * 10 + digit;
        self.operator_motion_count = if (next > MAX_VIM_COUNT) MAX_VIM_COUNT else next;
    }
};

fn parseFindType(key: u8) FindType {
    return switch (key) {
        'f' => .forward,
        'F' => .backward,
        't' => .until_forward,
        'T' => .until_backward,
        else => .forward,
    };
}

fn reverseFindType(find: FindType) FindType {
    return switch (find) {
        .forward => .backward,
        .backward => .forward,
        .until_forward => .until_backward,
        .until_backward => .until_forward,
    };
}

fn extractInsertedText(before: []const u8, before_cursor: usize, after: []const u8, after_cursor: usize) ?[]const u8 {
    if (after.len < before.len) return null;
    if (after_cursor < before_cursor) return null;

    const inserted_len = after.len - before.len;
    if (after_cursor - before_cursor != inserted_len) return null;
    if (before_cursor > before.len or after_cursor > after.len) return null;
    if (!std.mem.eql(u8, before[0..before_cursor], after[0..before_cursor])) return null;

    const before_suffix = before[before_cursor..];
    const after_suffix = after[after_cursor..];
    if (!std.mem.eql(u8, before_suffix, after_suffix)) return null;
    return after[before_cursor..after_cursor];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isBigWordChar(ch: u8) bool {
    return !isSpace(ch);
}

fn isPunctuationChar(ch: u8, word_pred: *const fn (u8) bool) bool {
    return !isSpace(ch) and !word_pred(ch);
}

const AtomKind = enum {
    space,
    word,
    punctuation,
    attachment,
};

const Atom = struct {
    kind: AtomKind,
    start: usize,
    end: usize,
};

const LogicalForwardRange = struct {
    end: usize,
    units: usize,
};

fn attachmentTokenAt(text: []const u8, pos: usize) ?repl_attachments.Token {
    if (text.len == 0 or pos >= text.len) return null;
    return repl_attachments.tokenAt(text, pos);
}

fn normalizeAttachmentCursor(text: []const u8, pos: usize) usize {
    if (text.len == 0) return 0;
    const clamped = @min(pos, text.len - 1);
    if (attachmentTokenAt(text, clamped)) |token| return token.start;
    return clamped;
}

fn atomAt(text: []const u8, pos: usize, word_pred: *const fn (u8) bool) ?Atom {
    if (text.len == 0 or pos >= text.len) return null;
    if (attachmentTokenAt(text, pos)) |token| {
        return .{ .kind = .attachment, .start = token.start, .end = token.end };
    }
    if (isSpace(text[pos])) {
        var start = pos;
        var end = pos;
        while (start > 0 and isSpace(text[start - 1])) : (start -= 1) {}
        while (end < text.len and isSpace(text[end])) : (end += 1) {}
        return .{ .kind = .space, .start = start, .end = end };
    }

    const kind: AtomKind = if (word_pred(text[pos])) .word else .punctuation;
    var start = pos;
    var end = pos + 1;

    while (start > 0) {
        if (attachmentTokenAt(text, start - 1) != null) break;
        if (isSpace(text[start - 1])) break;
        const matches = switch (kind) {
            .word => word_pred(text[start - 1]),
            .punctuation => !word_pred(text[start - 1]),
            else => false,
        };
        if (!matches) break;
        start -= 1;
    }

    while (end < text.len) {
        if (attachmentTokenAt(text, end) != null) break;
        if (isSpace(text[end])) break;
        const matches = switch (kind) {
            .word => word_pred(text[end]),
            .punctuation => !word_pred(text[end]),
            else => false,
        };
        if (!matches) break;
        end += 1;
    }

    return .{ .kind = kind, .start = start, .end = end };
}

fn logicalForwardRange(text: []const u8, pos: usize, count: usize) LogicalForwardRange {
    if (text.len == 0) return .{ .end = 0, .units = 0 };
    var cursor = normalizeAttachmentCursor(text, if (pos >= text.len) text.len - 1 else pos);
    var remaining = if (count == 0) @as(usize, 1) else count;
    var end = cursor;
    var units: usize = 0;

    while (remaining > 0) : (remaining -= 1) {
        if (attachmentTokenAt(text, cursor)) |token| {
            end = token.end;
        } else {
            end = @min(cursor + 1, text.len);
        }
        units += 1;
        if (end >= text.len) break;
        cursor = normalizeAttachmentCursor(text, end);
    }

    return .{ .end = end, .units = units };
}

fn lineStart(text: []const u8, pos: usize) usize {
    var i = @min(pos, text.len);
    while (i > 0 and text[i - 1] != '\n') : (i -= 1) {}
    return i;
}

fn lineEndExclusive(text: []const u8, pos: usize) usize {
    var i = @min(pos, text.len);
    while (i < text.len and text[i] != '\n') : (i += 1) {}
    return i;
}

fn lineLastChar(text: []const u8, pos: usize) usize {
    const start = lineStart(text, pos);
    const end = lineEndExclusive(text, pos);
    if (end > start) return normalizeAttachmentCursor(text, end - 1);
    return start;
}

fn firstNonBlank(text: []const u8, pos: usize) usize {
    const start = lineStart(text, pos);
    const end = lineEndExclusive(text, pos);
    var i = start;
    while (i < end and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    return if (i < end) i else start;
}

// Charwise left for an operator motion (dh): the exclusive start of the
// operated range, clamped so it never crosses the line start. Returns the
// position count chars left of pos but not before the current line's start.
fn charwiseLeftClamped(text: []const u8, pos: usize, count: usize) usize {
    const clamped = @min(pos, text.len);
    const start = lineStart(text, clamped);
    if (count >= clamped - start) return start;
    return clamped - count;
}

// Charwise right for an operator motion (dl): the exclusive end of the operated
// range, clamped so it never crosses the line end. dl deletes the char under
// the cursor, so the range is [cursor, cursor + count) capped at the line end.
fn charwiseRightClamped(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    const clamped = @min(pos, text.len);
    const end = lineEndExclusive(text, clamped);
    return @min(clamped + count, end);
}

fn moveLeft(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (i == 0) break;
        const prev = i - 1;
        i = if (attachmentTokenAt(text, prev)) |token| token.start else prev;
    }
    return i;
}

fn moveRight(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (attachmentTokenAt(text, i)) |token| {
            if (token.end >= text.len) break;
            i = normalizeAttachmentCursor(text, token.end);
        } else {
            if (i + 1 >= text.len) break;
            i = normalizeAttachmentCursor(text, i + 1);
        }
    }
    return i;
}

fn insertAfterCursor(text: []const u8, pos: usize) usize {
    if (text.len == 0) return 0;
    const clamped = normalizeAttachmentCursor(text, pos);
    if (attachmentTokenAt(text, clamped)) |token| return token.end;
    return @min(clamped + 1, text.len);
}

fn wordForwardExclusive(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = @min(pos, text.len);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (i >= text.len) break;
        const atom = atomAt(text, i, isWordChar) orelse break;
        i = atom.end;
        while (i < text.len and isSpace(text[i])) : (i += 1) {}
    }
    return i;
}

fn moveWordForward(text: []const u8, pos: usize, count: usize) usize {
    const target = wordForwardExclusive(text, pos, count);
    if (target >= text.len) return if (text.len == 0) 0 else normalizeAttachmentCursor(text, text.len - 1);
    return normalizeAttachmentCursor(text, target);
}

fn moveWordBackward(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, if (pos >= text.len) text.len - 1 else pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (i > 0 and !isSpace(text[i - 1])) {
            i = if (attachmentTokenAt(text, i - 1)) |token| token.start else i - 1;
        }
        while (i > 0 and isSpace(text[i])) : (i -= 1) {}
        if (isSpace(text[i])) return 0;
        const atom = atomAt(text, i, isWordChar) orelse return i;
        i = atom.start;
        if (remaining > 1 and i > 0) i -= 1;
    }
    return i;
}

fn moveWordEnd(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, if (pos >= text.len) text.len - 1 else pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        while (i < text.len and isSpace(text[i])) : (i += 1) {}
        if (i >= text.len) return text.len - 1;
        const atom = atomAt(text, i, isWordChar) orelse return i;
        i = atom.end - 1;
        if (remaining > 1 and i + 1 < text.len) i += 1;
    }
    return i;
}

// WORD (capital W/B/E) motions classify a WORD as a run of non-whitespace.
// They mirror the lowercase word helpers above but pass isBigWordChar to atomAt
// so punctuation does not break a WORD apart.
fn bigWordForwardExclusive(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = @min(pos, text.len);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        if (i >= text.len) break;
        const atom = atomAt(text, i, isBigWordChar) orelse break;
        i = atom.end;
        while (i < text.len and isSpace(text[i])) : (i += 1) {}
    }
    return i;
}

fn moveBigWordForward(text: []const u8, pos: usize, count: usize) usize {
    const target = bigWordForwardExclusive(text, pos, count);
    if (target >= text.len) return if (text.len == 0) 0 else normalizeAttachmentCursor(text, text.len - 1);
    return normalizeAttachmentCursor(text, target);
}

fn moveBigWordBackward(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, if (pos >= text.len) text.len - 1 else pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        // Step back at least one position so that B from a WORD start crosses
        // the gap into the previous WORD (vim semantics). Honor attachment
        // tokens by jumping to their start.
        if (i > 0) {
            i = if (attachmentTokenAt(text, i - 1)) |token| token.start else i - 1;
        }
        while (i > 0 and isSpace(text[i])) : (i -= 1) {}
        if (isSpace(text[i])) return 0;
        const atom = atomAt(text, i, isBigWordChar) orelse return i;
        i = atom.start;
        if (remaining > 1 and i > 0) i -= 1;
    }
    return i;
}

fn moveBigWordEnd(text: []const u8, pos: usize, count: usize) usize {
    if (text.len == 0) return 0;
    var i = normalizeAttachmentCursor(text, if (pos >= text.len) text.len - 1 else pos);
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        while (i < text.len and isSpace(text[i])) : (i += 1) {}
        if (i >= text.len) return text.len - 1;
        const atom = atomAt(text, i, isBigWordChar) orelse return i;
        i = atom.end - 1;
        if (remaining > 1 and i + 1 < text.len) i += 1;
    }
    return i;
}

fn currentColumn(text: []const u8, pos: usize) usize {
    const start = lineStart(text, pos);
    const end = lineEndExclusive(text, pos);
    return @min(pos, end) - start;
}

fn moveVertical(text: []const u8, pos: usize, count: usize, down: bool) usize {
    if (text.len == 0) return 0;

    const desired_col = currentColumn(text, pos);
    var start = lineStart(text, pos);
    var remaining = count;

    while (remaining > 0) : (remaining -= 1) {
        if (down) {
            const end = lineEndExclusive(text, start);
            if (end >= text.len) break;
            start = @min(end + 1, text.len);
        } else {
            if (start == 0) break;
            start = lineStart(text, start - 1);
        }
    }

    if (start >= text.len) return text.len - 1;
    const end = lineEndExclusive(text, start);
    if (end > start) return normalizeAttachmentCursor(text, @min(start + desired_col, end - 1));
    return normalizeAttachmentCursor(text, start);
}

fn lineRangeForCount(text: []const u8, pos: usize, count: usize) Range {
    var start = lineStart(text, pos);
    var end = start;
    var remaining = count;

    while (remaining > 0) : (remaining -= 1) {
        const line_end = lineEndExclusive(text, end);
        end = line_end;
        if (end < text.len and text[end] == '\n') end += 1;
        if (end >= text.len) break;
    }

    if (end == text.len and start > 0 and text[start - 1] == '\n') {
        start -= 1;
    }

    return .{ .start = start, .end = end };
}

// Linewise range spanning every full line between the lines containing pos_a
// and pos_b (inclusive of both). Used by operator+G / operator+gg. The trailing
// newline is included so the lines are actually removed; when the span reaches
// end-of-file with no trailing newline, the preceding newline is folded in so
// no orphan blank line is left behind (mirrors operators.ts:451-464).
fn linewiseRangeBetween(text: []const u8, pos_a: usize, pos_b: usize) Range {
    if (text.len == 0) return .{ .start = 0, .end = 0 };
    const a = @min(pos_a, text.len);
    const b = @min(pos_b, text.len);
    const lo = @min(a, b);
    const hi = @max(a, b);

    var start = lineStart(text, lo);
    var end = lineEndExclusive(text, hi);
    if (end < text.len and text[end] == '\n') {
        end += 1;
    } else {
        end = text.len;
        if (start > 0 and text[start - 1] == '\n') start -= 1;
    }

    return .{ .start = start, .end = end };
}

fn moveToFirstLine(text: []const u8, count: usize) usize {
    if (count <= 1 or text.len == 0) return 0;
    var line_no: usize = 1;
    var i: usize = 0;
    while (i < text.len and line_no < count) : (i += 1) {
        if (text[i] == '\n') line_no += 1;
    }
    return if (i >= text.len) lineStart(text, text.len - 1) else i;
}

fn moveToLastLine(text: []const u8, count: usize) usize {
    if (text.len == 0) return 0;
    if (count > 1) return moveToFirstLine(text, count);
    return lineStart(text, text.len - 1);
}

fn findCharacterTarget(text: []const u8, pos: usize, needle: u8, count: usize, find: FindType) ?usize {
    if (text.len == 0 or pos >= text.len) return null;
    const wanted = if (count == 0) 1 else count;

    switch (find) {
        .forward, .until_forward => {
            var remaining = wanted;
            var i = pos + 1;
            while (i < text.len) {
                if (attachmentTokenAt(text, i)) |token| {
                    i = token.end;
                    continue;
                }
                if (text[i] == needle) {
                    remaining -= 1;
                    if (remaining == 0) {
                        return if (find == .forward) i else if (i > 0) i - 1 else null;
                    }
                }
                i += 1;
            }
        },
        .backward, .until_backward => {
            if (pos == 0) return null;
            var remaining = wanted;
            var i: isize = @as(isize, @intCast(pos)) - 1;
            while (i >= 0) {
                const idx: usize = @intCast(i);
                if (attachmentTokenAt(text, idx)) |token| {
                    i = @as(isize, @intCast(token.start)) - 1;
                    continue;
                }
                if (text[idx] == needle) {
                    remaining -= 1;
                    if (remaining == 0) {
                        return if (find == .backward) idx else @min(idx + 1, text.len - 1);
                    }
                }
                i -= 1;
            }
        },
    }

    return null;
}

fn findTextObjectRange(text: []const u8, pos: usize, obj_type: u8, scope: TextObjectScope) ?Range {
    if (text.len == 0) return null;
    return switch (obj_type) {
        'w' => findWordObjectRange(text, pos, scope, isWordChar),
        'W' => findWordObjectRange(text, pos, scope, isBigWordChar),
        '"', '\'', '`' => findQuoteObjectRange(text, pos, obj_type, scope),
        '(', ')', 'b' => findBracketObjectRange(text, pos, '(', ')', scope),
        '[', ']' => findBracketObjectRange(text, pos, '[', ']', scope),
        '{', '}', 'B' => findBracketObjectRange(text, pos, '{', '}', scope),
        '<', '>' => findBracketObjectRange(text, pos, '<', '>', scope),
        else => null,
    };
}

fn findWordObjectRange(text: []const u8, pos: usize, scope: TextObjectScope, word_pred: *const fn (u8) bool) ?Range {
    if (text.len == 0) return null;
    const idx = @min(pos, text.len - 1);
    if (attachmentTokenAt(text, idx)) |token| {
        var start = token.start;
        var end = token.end;
        if (scope == .around) {
            if (end < text.len and isSpace(text[end])) {
                while (end < text.len and isSpace(text[end])) : (end += 1) {}
            } else {
                while (start > 0 and isSpace(text[start - 1])) : (start -= 1) {}
            }
        }
        return .{ .start = start, .end = end };
    }
    var start = idx;
    var end = idx + 1;

    if (word_pred(text[idx])) {
        while (start > 0 and word_pred(text[start - 1])) : (start -= 1) {}
        while (end < text.len and word_pred(text[end])) : (end += 1) {}
    } else if (isSpace(text[idx])) {
        while (start > 0 and isSpace(text[start - 1])) : (start -= 1) {}
        while (end < text.len and isSpace(text[end])) : (end += 1) {}
        return .{ .start = start, .end = end };
    } else if (isPunctuationChar(text[idx], word_pred)) {
        while (start > 0 and isPunctuationChar(text[start - 1], word_pred)) : (start -= 1) {}
        while (end < text.len and isPunctuationChar(text[end], word_pred)) : (end += 1) {}
    } else {
        return null;
    }

    if (scope == .around) {
        if (end < text.len and isSpace(text[end])) {
            while (end < text.len and isSpace(text[end])) : (end += 1) {}
        } else {
            while (start > 0 and isSpace(text[start - 1])) : (start -= 1) {}
        }
    }

    return .{ .start = start, .end = end };
}

fn findQuoteObjectRange(text: []const u8, pos: usize, quote: u8, scope: TextObjectScope) ?Range {
    const start_line = lineStart(text, pos);
    const end_line = lineEndExclusive(text, pos);
    var first_quote: ?usize = null;
    var i = start_line;
    while (i < end_line) {
        if (attachmentTokenAt(text, i)) |token| {
            i = token.end;
            continue;
        }
        if (text[i] != quote) {
            i += 1;
            continue;
        }
        if (first_quote == null) {
            first_quote = i;
            i += 1;
            continue;
        }
        const open_idx = first_quote.?;
        const close_idx = i;
        if (open_idx <= pos and pos <= close_idx) {
            return if (scope == .inner)
                .{ .start = open_idx + 1, .end = close_idx }
            else
                .{ .start = open_idx, .end = close_idx + 1 };
        }
        first_quote = null;
        i += 1;
    }
    return null;
}

fn findBracketObjectRange(text: []const u8, pos: usize, open: u8, close: u8, scope: TextObjectScope) ?Range {
    if (text.len == 0) return null;
    var depth: usize = 0;
    var start: ?usize = null;
    var i: isize = @as(isize, @intCast(@min(pos, text.len - 1)));
    while (i >= 0) {
        const idx: usize = @intCast(i);
        if (attachmentTokenAt(text, idx)) |token| {
            i = @as(isize, @intCast(token.start)) - 1;
            continue;
        }
        if (text[idx] == close and idx != pos) {
            depth += 1;
        } else if (text[idx] == open) {
            if (depth == 0) {
                start = idx;
                break;
            }
            depth -= 1;
        }
        i -= 1;
    }
    if (start == null) return null;

    depth = 0;
    var end: ?usize = null;
    var j = start.? + 1;
    while (j < text.len) {
        if (attachmentTokenAt(text, j)) |token| {
            j = token.end;
            continue;
        }
        if (text[j] == open) {
            depth += 1;
        } else if (text[j] == close) {
            if (depth == 0) {
                end = j;
                break;
            }
            depth -= 1;
        }
        j += 1;
    }
    if (end == null) return null;

    return if (scope == .inner)
        .{ .start = start.? + 1, .end = end.? }
    else
        .{ .start = start.?, .end = end.? + 1 };
}

const testing = std.testing;

test "dw deletes the current word and stores a charwise register" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello world");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("world", input.items());
    try testing.expectEqualStrings("hello ", state.register.items());
    try testing.expect(!state.register_linewise);
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "cw changes to the word end and preserves the trailing space, unlike dw" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello world");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'c');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expect(result.enter_insert);
    // cw stops at the word end: "hello" is removed but the space survives.
    try testing.expectEqualStrings(" world", input.items());
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "dw still consumes the trailing whitespace on the same input" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello world");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expect(!result.enter_insert);
    // dw removes the word plus the following whitespace.
    try testing.expectEqualStrings("world", input.items());
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "cW changes to the WORD end and preserves the trailing space, unlike dW" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'c');
    const result = try state.handleNormalKey(&input, &cursor, 'W');

    try testing.expect(result.modified);
    try testing.expect(result.enter_insert);
    // cW stops at the WORD end (punctuation does not break a WORD): "foo.bar"
    // is removed but the space survives, unlike dW which consumes it.
    try testing.expectEqualStrings(" baz", input.items());
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "cw dot-repeats with the word-end semantics preserved" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("alpha beta");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'c');
    _ = try state.handleNormalKey(&input, &cursor, 'w');
    // The change op leaves us in insert mode; return to normal to dot-repeat.
    try testing.expectEqualStrings(" beta", input.items());
    state.mode = .normal;

    // Move onto the start of "beta" (index 1) and replay the recorded cw.
    cursor = 1;
    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    // The repeat must also stop at the word end, not the next word start.
    try testing.expectEqualStrings(" ", input.items());
}

test "Y yanks the whole current line linewise like yy" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("alpha\nbeta");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'Y');

    try testing.expect(state.register_linewise);
    try testing.expectEqualStrings("alpha\n", state.register.items());
    // Yank must not modify the buffer.
    try testing.expectEqualStrings("alpha\nbeta", input.items());
}

test "Y with a count captures multiple lines" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("alpha\nbeta\ngamma");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '2');
    _ = try state.handleNormalKey(&input, &cursor, 'Y');

    try testing.expect(state.register_linewise);
    try testing.expectEqualStrings("alpha\nbeta\n", state.register.items());
    try testing.expectEqualStrings("alpha\nbeta\ngamma", input.items());
}

test "yy and p duplicate the current line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("alpha\nbeta");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'y');
    _ = try state.handleNormalKey(&input, &cursor, 'y');
    const result = try state.handleNormalKey(&input, &cursor, 'p');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("alpha\nalpha\nbeta", input.items());
    try testing.expect(state.register_linewise);
    try testing.expectEqualStrings("alpha\n", state.register.items());
}

test "o inserts a new blank line and enters insert mode" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("alpha");
    var cursor: usize = 2;

    const result = try state.handleNormalKey(&input, &cursor, 'o');
    if (result.enter_insert) try state.enterInsert(input.items(), cursor);

    try testing.expect(result.modified);
    try testing.expectEqualStrings("alpha\n", input.items());
    try testing.expectEqual(Mode.insert, state.mode);
    try testing.expectEqual(@as(usize, input.items().len), cursor);
}

test "insert dot repeat replays the typed insertion" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("ab");
    var cursor: usize = 1;

    try state.enterInsert(input.items(), cursor);
    var insert_cursor = cursor;
    try repl_input.insertInputBytesAt(&input, &insert_cursor, "XY");
    cursor = insert_cursor;
    try state.enterNormal(input.items(), &cursor);

    try testing.expectEqualStrings("aXYb", input.items());
    try testing.expectEqual(Mode.normal, state.mode);

    cursor = input.items().len - 1;
    const result = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(result.modified);
    try testing.expectEqualStrings("aXYXYb", input.items());
}

test "diw deletes the current word" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("one two three");
    var cursor: usize = 5;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'i');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("one  three", input.items());
}

test "cit quote object enters insert mode after removing quoted content" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("say \"hello\" now");
    var cursor: usize = 6;

    _ = try state.handleNormalKey(&input, &cursor, 'c');
    _ = try state.handleNormalKey(&input, &cursor, 'i');
    const result = try state.handleNormalKey(&input, &cursor, '"');

    try testing.expect(result.modified);
    try testing.expect(result.enter_insert);
    try testing.expectEqualStrings("say \"\" now", input.items());
}

test "dfx deletes through the found character" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("abcxdef");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'f');
    const result = try state.handleNormalKey(&input, &cursor, 'x');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("def", input.items());
}

test "d2w uses an operator motion count" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("one two three four");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, '2');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("three four", input.items());
}

test "x deletes an attachment token atomically" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("<@image:1> tail");
    var cursor: usize = 0;

    const result = try state.handleNormalKey(&input, &cursor, 'x');

    try testing.expect(result.modified);
    try testing.expectEqualStrings(" tail", input.items());
}

test "diw treats attachment tokens as single text objects" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("look <@paste:2> here");
    var cursor: usize = 5;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'i');
    const result = try state.handleNormalKey(&input, &cursor, 'w');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("look  here", input.items());
}

test "W jumps over punctuation to the next WORD start" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'W');

    // "foo.bar" is one WORD; W lands on 'b' of "baz" at index 8, not "bar".
    try testing.expectEqual(@as(usize, 8), cursor);
}

test "E lands on the last char of the current WORD" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'E');

    // Last char of WORD "foo.bar" is the 'r' at index 6.
    try testing.expectEqual(@as(usize, 6), cursor);
}

test "B moves back to the previous WORD start" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz");
    var cursor: usize = 8;

    _ = try state.handleNormalKey(&input, &cursor, 'B');

    // From 'b' of "baz", B lands on the start of WORD "foo.bar" at index 0.
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "dW deletes a whole WORD including trailing whitespace" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'W');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("baz", input.items());
    try testing.expectEqualStrings("foo.bar ", state.register.items());
}

test "dW dot-repeats by replaying the recorded WORD motion" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo.bar baz.qux end");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'W');
    try testing.expectEqualStrings("baz.qux end", input.items());

    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("end", input.items());
}

test "dj deletes the current line and the next line linewise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\nbar");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'j');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("", input.items());
    try testing.expect(state.register_linewise);
}

test "dk deletes the current line and the previous line linewise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\nbar");
    // Cursor on the second line ("bar").
    var cursor: usize = 4;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'k');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("", input.items());
    try testing.expect(state.register_linewise);
}

test "dj leaves the lines below intact and is linewise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\nbar\nbaz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'j');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("baz", input.items());
    try testing.expect(state.register_linewise);
}

test "dl deletes one charwise character under the cursor" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'l');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("ello", input.items());
    try testing.expect(!state.register_linewise);
}

test "2dl deletes two charwise characters" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, '2');
    const result = try state.handleNormalKey(&input, &cursor, 'l');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("llo", input.items());
    try testing.expect(!state.register_linewise);
}

test "dl clamps at the line end and does not cross a newline" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("ab\ncd");
    // Cursor on the last char of the first line.
    var cursor: usize = 1;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, '5');
    const result = try state.handleNormalKey(&input, &cursor, 'l');

    try testing.expect(result.modified);
    // Only "b" is removed; the newline and second line stay intact.
    try testing.expectEqualStrings("a\ncd", input.items());
}

test "dh deletes the character to the left charwise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("hello");
    var cursor: usize = 2;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'h');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("hllo", input.items());
    try testing.expect(!state.register_linewise);
}

test "db deletes back to the start of the word charwise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo bar");
    // Cursor in the middle of "bar" (on the 'r'); db deletes back to the word
    // start, removing "ba" and leaving the rest of the line intact.
    var cursor: usize = 6;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'b');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("foo r", input.items());
    try testing.expect(!state.register_linewise);
}

test "db from a space deletes the previous word charwise" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo bar");
    // Cursor on the space after "foo"; db deletes the previous word "foo".
    var cursor: usize = 3;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'b');

    try testing.expect(result.modified);
    try testing.expectEqualStrings(" bar", input.items());
    try testing.expect(!state.register_linewise);
}

test "dj dot-repeats by replaying the recorded linewise motion" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("a\nb\nc\nd");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'j');
    try testing.expectEqualStrings("c\nd", input.items());

    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("", input.items());
}

test "tilde toggles the case under the cursor and advances" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aB");
    var cursor: usize = 0;

    const result = try state.handleNormalKey(&input, &cursor, '~');

    // A single ~ toggles only the char under the cursor (index 0): a -> A.
    try testing.expect(result.modified);
    try testing.expectEqualStrings("AB", input.items());
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "count tilde toggles multiple characters" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aB");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '2');
    const result = try state.handleNormalKey(&input, &cursor, '~');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("Ab", input.items());
    // Cursor clamps to the last char of the line, never past EOL.
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "dot repeats the last tilde toggle" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("abc");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '~');
    try testing.expectEqualStrings("Abc", input.items());
    try testing.expectEqual(@as(usize, 1), cursor);

    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("ABc", input.items());
    try testing.expectEqual(@as(usize, 2), cursor);
}

test "tilde does not cross the line boundary" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aB\ncd");
    var cursor: usize = 0;

    // A large count is clamped to the end of the current line.
    _ = try state.handleNormalKey(&input, &cursor, '9');
    const result = try state.handleNormalKey(&input, &cursor, '~');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("Ab\ncd", input.items());
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "J joins the next line trimming leading whitespace into a single space" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\n   bar");
    var cursor: usize = 0;

    const result = try state.handleNormalKey(&input, &cursor, 'J');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("foo bar", input.items());
    // Cursor lands on the join seam (the inserted space at index 3).
    try testing.expectEqual(@as(usize, 3), cursor);
}

test "J on a single line is a no-op" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("only");
    var cursor: usize = 1;

    const result = try state.handleNormalKey(&input, &cursor, 'J');

    try testing.expect(!result.modified);
    try testing.expectEqualStrings("only", input.items());
    try testing.expectEqual(@as(usize, 1), cursor);
}

test "count J joins multiple following lines" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\n bar\n  baz");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '2');
    const result = try state.handleNormalKey(&input, &cursor, 'J');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("foo bar baz", input.items());
}

test "dot repeats the last J join" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("a\nb\nc");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'J');
    try testing.expectEqualStrings("a b\nc", input.items());
    try testing.expectEqual(@as(usize, 1), cursor);

    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("a b c", input.items());
}

test ">> indents the current line by two spaces" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo");
    var cursor: usize = 1;

    const pending = try state.handleNormalKey(&input, &cursor, '>');
    try testing.expect(!pending.modified);
    const result = try state.handleNormalKey(&input, &cursor, '>');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("  foo", input.items());
    // Cursor lands at the first non-blank (the 'f' now at index 2).
    try testing.expectEqual(@as(usize, 2), cursor);
}

test "<< dedents a two-space indented line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("    foo");
    var cursor: usize = 5;

    _ = try state.handleNormalKey(&input, &cursor, '<');
    const result = try state.handleNormalKey(&input, &cursor, '<');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("  foo", input.items());
    try testing.expectEqual(@as(usize, 2), cursor);
}

test "<< strips a single leading tab" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("\tfoo");
    var cursor: usize = 1;

    _ = try state.handleNormalKey(&input, &cursor, '<');
    const result = try state.handleNormalKey(&input, &cursor, '<');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("foo", input.items());
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "2>> indents two lines" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo\nbar");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '2');
    _ = try state.handleNormalKey(&input, &cursor, '>');
    const result = try state.handleNormalKey(&input, &cursor, '>');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("  foo\n  bar", input.items());
}

test "dot repeats the last >> indent" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '>');
    _ = try state.handleNormalKey(&input, &cursor, '>');
    try testing.expectEqualStrings("  foo", input.items());

    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("    foo", input.items());
}

test "an indent key that is not doubled clears pending without modifying" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("foo");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, '>');
    // A non-'>' key (here 'x') must clear pending without modifying the buffer.
    const result = try state.handleNormalKey(&input, &cursor, 'x');

    try testing.expect(!result.modified);
    try testing.expectEqualStrings("foo", input.items());
    try testing.expectEqual(Pending.none, state.pending);
}

test "dG deletes from the cursor line to the last line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    const result = try state.handleNormalKey(&input, &cursor, 'G');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("", input.items());
    try testing.expect(state.register_linewise);
}

test "dgg deletes from the last line up to the first line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 8; // start of "ccc"

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'g');
    const result = try state.handleNormalKey(&input, &cursor, 'g');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("", input.items());
}

test "d2G deletes linewise from the cursor line to line 2" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, '2');
    const result = try state.handleNormalKey(&input, &cursor, 'G');

    try testing.expect(result.modified);
    try testing.expectEqualStrings("ccc", input.items());
}

test "cG deletes to the last line and enters insert mode" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("one\ntwo\nthree");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'c');
    const result = try state.handleNormalKey(&input, &cursor, 'G');

    try testing.expect(result.modified);
    try testing.expect(result.enter_insert);
    try testing.expectEqualStrings("", input.items());
}

test "yG yanks the cursor-line-to-last-line span linewise without modifying" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 4; // start of "bbb"

    _ = try state.handleNormalKey(&input, &cursor, 'y');
    const result = try state.handleNormalKey(&input, &cursor, 'G');

    try testing.expect(!result.modified);
    try testing.expectEqualStrings("aaa\nbbb\nccc", input.items());
    try testing.expect(state.register_linewise);
    try testing.expectEqualStrings("bbb\nccc\n", state.register.items());
}

test "dot repeats the last dG" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("a\nb\nc\nd");
    var cursor: usize = 0;

    // dG on the first two lines, then undo-by-text and re-run via dot.
    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, '2');
    _ = try state.handleNormalKey(&input, &cursor, 'G');
    try testing.expectEqualStrings("c\nd", input.items());

    // The recorded change is a linewise dG to line 2; on the remaining buffer
    // line 2 is the last line, so dot deletes both remaining lines.
    cursor = 0;
    const repeat = try state.handleNormalKey(&input, &cursor, '.');
    try testing.expect(repeat.modified);
    try testing.expectEqualStrings("", input.items());
}

test "gj moves down one logical line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 1; // index 1 on line 1 (column 1)

    _ = try state.handleNormalKey(&input, &cursor, 'g');
    _ = try state.handleNormalKey(&input, &cursor, 'j');

    // Down one line keeping the column: index 5 ('b' at column 1 of "bbb").
    try testing.expectEqual(@as(usize, 5), cursor);
}

test "gk moves up one logical line" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 9; // index 9 on line 3 (column 1)

    _ = try state.handleNormalKey(&input, &cursor, 'g');
    _ = try state.handleNormalKey(&input, &cursor, 'k');

    // Up one line keeping the column: index 5 (column 1 of "bbb").
    try testing.expectEqual(@as(usize, 5), cursor);
}

test "operator+g that is not gg clears cleanly without modifying" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    try input.appendSlice("aaa\nbbb\nccc");
    var cursor: usize = 0;

    _ = try state.handleNormalKey(&input, &cursor, 'd');
    _ = try state.handleNormalKey(&input, &cursor, 'g');
    // A non-'g' second key (here 'x') must abort the operator without changes.
    const result = try state.handleNormalKey(&input, &cursor, 'x');

    try testing.expect(!result.modified);
    try testing.expectEqualStrings("aaa\nbbb\nccc", input.items());
    try testing.expectEqual(Pending.none, state.pending);
    try testing.expect(state.pending_g_operator == null);
}

test "count prefix clamps to MAX_VIM_COUNT (10000)" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    var cursor: usize = 0;

    // Typing "10000" should land on exactly 10000, not roll past it.
    for ("10000") |digit| {
        _ = try state.handleNormalKey(&input, &cursor, digit);
    }
    try testing.expectEqual(@as(usize, 10000), state.count);
}

test "count prefix beyond MAX_VIM_COUNT stays clamped at 10000" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    var cursor: usize = 0;

    // Typing "10001" must still clamp to 10000.
    for ("10001") |digit| {
        _ = try state.handleNormalKey(&input, &cursor, digit);
    }
    try testing.expectEqual(@as(usize, 10000), state.count);
}

test "operator motion count prefix clamps to MAX_VIM_COUNT (10000)" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    state.setEnabled(true);
    state.mode = .normal;

    var input = std_io.StringBuilder.init(testing.allocator);
    defer input.deinit();
    var cursor: usize = 0;

    // Enter operator-pending mode, then type a count for the motion.
    _ = try state.handleNormalKey(&input, &cursor, 'd');
    for ("10001") |digit| {
        _ = try state.handleNormalKey(&input, &cursor, digit);
    }
    try testing.expectEqual(@as(usize, 10000), state.operator_motion_count);
}
