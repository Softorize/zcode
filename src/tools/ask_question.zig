//! AskUserQuestion parsing + answer serialization (Phase 9 Task 5 / tools-04).
//!
//! Expands AskUserQuestion from a single free-text `{question, choices}` shape
//! to the reference Claude Code shape: 1-4 questions, each with a `header` chip
//! (<= 12 chars), 2-4 rich options (`label`, `description`, optional `preview`),
//! and a `multiSelect` flag. Returns per-question structured answers.
//!
//! Reference: claude-code-main AskUserQuestionTool.tsx:14-74 (option schema with
//! `preview`; question schema with `header`/`options.min(2).max(4)`/`multiSelect`;
//! inputSchema `questions.min(1).max(4)`; output: per-question answers, multi-select
//! comma-joined).
//!
//! The interactive selection UI itself lives in the REPL overlay; this module is
//! the network-free, unit-testable parse + serialize core. The dispatch layer
//! drives one UI prompt per parsed `Question` and assembles `Answer`s.

const std = @import("std");

/// Maximum number of characters allowed in a question `header` chip. Longer
/// headers are truncated. Mirrors the reference's `<= 12-char chip label` rule.
pub const MAX_HEADER_LEN: usize = 12;

/// Reference clamp on options per question. The reference enforces
/// `options.min(2).max(4)`. We reject < 2 (a closed single-option question is
/// useless) and cap > 4.
pub const MIN_OPTIONS: usize = 2;
pub const MAX_OPTIONS: usize = 4;

/// Reference clamp on questions per call: `questions.min(1).max(4)`.
pub const MAX_QUESTIONS: usize = 4;

/// One selectable option within a question. All strings are owned by the
/// enclosing `Questions` arena-free model: they are individually duped at parse
/// time and freed in `Questions.deinit`.
pub const Option = struct {
    label: []const u8,
    description: []const u8 = "",
    /// Optional rich preview (markdown/text) shown alongside the focused option.
    preview: ?[]const u8 = null,
};

/// One question with its header chip, options, and multi-select flag.
pub const Question = struct {
    question: []const u8,
    /// <= 12-char chip label. Empty when the model omitted it.
    header: []const u8 = "",
    multi_select: bool = false,
    options: []Option,
};

/// A parsed AskUserQuestion payload: 1-4 questions plus the owning allocator so
/// `deinit` can free every duped string and slice.
pub const Questions = struct {
    items: []Question,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Questions) void {
        const a = self.allocator;
        for (self.items) |q| {
            a.free(q.question);
            a.free(q.header);
            for (q.options) |opt| {
                a.free(opt.label);
                a.free(opt.description);
                if (opt.preview) |p| a.free(p);
            }
            a.free(q.options);
        }
        a.free(self.items);
    }
};

/// One resolved per-question answer. `value` is the selected label (or, for a
/// multi-select question, the selected labels joined with ", ").
pub const Answer = struct {
    question: []const u8,
    value: []const u8,
};

pub const ParseError = error{
    /// No questions could be extracted from the payload.
    NoQuestions,
    /// A question carried fewer than MIN_OPTIONS usable options.
    TooFewOptions,
} || std.mem.Allocator.Error;

/// Parse an AskUserQuestion args payload into structured questions.
///
/// Accepts two shapes:
///   1. New reference shape: `{"questions":[{"question","header","multiSelect",
///      "options":[{"label","description","preview"}]}]}`.
///   2. Legacy shape: `{"question":"...","choices":"[...]"}` (or `options`).
///      Wrapped into a single `Question` with synthesized options so existing
///      callers keep working.
///
/// `args` is the raw tool-args JSON object string. On a payload that is neither
/// shape (e.g. a bare string), returns `error.NoQuestions`.
pub fn parseQuestions(allocator: std.mem.Allocator, args: []const u8) ParseError!Questions {
    const trimmed = std.mem.trim(u8, args, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.NoQuestions;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return error.NoQuestions;
    defer parsed.deinit();
    if (parsed.value != .object) return error.NoQuestions;
    const root = parsed.value.object;

    // New shape: a top-level "questions" array.
    if (root.get("questions")) |questions_val| {
        if (questions_val == .array) {
            return parseQuestionsArray(allocator, questions_val.array.items);
        }
    }

    // Legacy shape: top-level "question" + "choices"/"options".
    if (root.get("question")) |question_val| {
        if (question_val == .string) {
            return parseLegacyQuestion(allocator, root, question_val.string);
        }
    }

    return error.NoQuestions;
}

/// Parse the new `questions` array into owned `Question` structs. Clamps each
/// question's options to [MIN_OPTIONS, MAX_OPTIONS] and the question count to
/// MAX_QUESTIONS. A question with fewer than MIN_OPTIONS usable options causes
/// `error.TooFewOptions`.
fn parseQuestionsArray(allocator: std.mem.Allocator, raw_items: []const std.json.Value) ParseError!Questions {
    var out = std.array_list.Managed(Question).init(allocator);
    errdefer {
        for (out.items) |q| freeQuestion(allocator, q);
        out.deinit();
    }

    for (raw_items) |item| {
        if (out.items.len >= MAX_QUESTIONS) break;
        if (item != .object) continue;
        const obj = item.object;

        const q_text = stringField(obj, "question") orelse continue;
        const header_raw = stringField(obj, "header") orelse "";
        const multi = boolField(obj, "multiSelect");

        const options = try parseOptions(allocator, obj);
        if (options.len < MIN_OPTIONS) {
            freeOptions(allocator, options);
            // Surface a clear error so the model retries with >= 2 options,
            // mirroring the reference's `options.min(2)` validation.
            return error.TooFewOptions;
        }
        errdefer freeOptions(allocator, options);

        const question = Question{
            .question = try allocator.dupe(u8, q_text),
            .header = try dupTruncatedHeader(allocator, header_raw),
            .multi_select = multi,
            .options = options,
        };
        try out.append(question);
    }

    if (out.items.len == 0) {
        out.deinit();
        return error.NoQuestions;
    }

    return .{ .items = try out.toOwnedSlice(), .allocator = allocator };
}

/// Parse the `options` array of one question object into owned `Option`s,
/// capped at MAX_OPTIONS. Each option must carry a non-empty `label` (or a
/// fallback key). Options without a usable label are skipped.
fn parseOptions(allocator: std.mem.Allocator, question_obj: std.json.ObjectMap) ParseError![]Option {
    var out = std.array_list.Managed(Option).init(allocator);
    errdefer {
        freeOptionList(allocator, out.items);
        out.deinit();
    }

    const options_val = question_obj.get("options") orelse return out.toOwnedSlice();
    if (options_val != .array) return out.toOwnedSlice();

    for (options_val.array.items) |opt_item| {
        if (out.items.len >= MAX_OPTIONS) break;
        switch (opt_item) {
            // Tolerate a plain string option (`["a","b"]`) -- some models emit
            // the simpler form even under the rich schema.
            .string => |s| {
                if (s.len == 0) continue;
                try out.append(.{
                    .label = try allocator.dupe(u8, s),
                    .description = try allocator.dupe(u8, ""),
                    .preview = null,
                });
            },
            .object => |o| {
                const label = extractLabel(o) orelse continue;
                const desc = stringField(o, "description") orelse "";
                const preview: ?[]const u8 = if (stringField(o, "preview")) |p|
                    try allocator.dupe(u8, p)
                else
                    null;
                errdefer if (preview) |p| allocator.free(p);
                try out.append(.{
                    .label = try allocator.dupe(u8, label),
                    .description = try allocator.dupe(u8, desc),
                    .preview = preview,
                });
            },
            else => {},
        }
    }

    return out.toOwnedSlice();
}

/// Wrap a legacy `{question, choices}` payload into a single-question
/// `Questions`. Choices come from `choices` or `options` (string array, option
/// objects, or delimited string) via the same tolerant rules the old parser
/// used, so the legacy back-compat tests keep passing.
fn parseLegacyQuestion(allocator: std.mem.Allocator, root: std.json.ObjectMap, question_text: []const u8) ParseError!Questions {
    const choices_val = root.get("choices") orelse root.get("options");

    var opts = std.array_list.Managed(Option).init(allocator);
    errdefer {
        freeOptionList(allocator, opts.items);
        opts.deinit();
    }

    if (choices_val) |cv| {
        switch (cv) {
            // choices delivered as a JSON string (the legacy schema declares
            // `choices` as a string field, so the model passes a stringified
            // JSON array). Re-parse it.
            .string => |s| try appendLabelsFromRawString(allocator, &opts, s),
            .array => |arr| try appendLabelsFromArray(allocator, &opts, arr.items),
            else => {},
        }
    }

    const options = try opts.toOwnedSlice();
    errdefer freeOptions(allocator, options);

    var items = try allocator.alloc(Question, 1);
    errdefer allocator.free(items);
    items[0] = .{
        .question = try allocator.dupe(u8, question_text),
        .header = try allocator.dupe(u8, ""),
        .multi_select = false,
        .options = options,
    };
    return .{ .items = items, .allocator = allocator };
}

/// Append options parsed from a raw string that is either a JSON array
/// (`["a","b"]` or `[{"label":"a"}]`) or a delimited string (`a, b | c`).
fn appendLabelsFromRawString(allocator: std.mem.Allocator, out: *std.array_list.Managed(Option), raw: []const u8) ParseError!void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return;

    if (trimmed[0] == '[') {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            return appendLabelsFromDelimited(allocator, out, trimmed);
        };
        defer parsed.deinit();
        if (parsed.value == .array) {
            try appendLabelsFromArray(allocator, out, parsed.value.array.items);
            return;
        }
        return appendLabelsFromDelimited(allocator, out, trimmed);
    }

    return appendLabelsFromDelimited(allocator, out, trimmed);
}

/// Append options from an already-parsed JSON array (strings or option objects).
fn appendLabelsFromArray(allocator: std.mem.Allocator, out: *std.array_list.Managed(Option), items: []const std.json.Value) ParseError!void {
    for (items) |item| {
        switch (item) {
            .string => |s| {
                if (s.len == 0) continue;
                try out.append(.{
                    .label = try allocator.dupe(u8, s),
                    .description = try allocator.dupe(u8, ""),
                    .preview = null,
                });
            },
            .object => |o| {
                const label = extractLabel(o) orelse continue;
                const desc = stringField(o, "description") orelse "";
                const preview: ?[]const u8 = if (stringField(o, "preview")) |p|
                    try allocator.dupe(u8, p)
                else
                    null;
                errdefer if (preview) |p| allocator.free(p);
                try out.append(.{
                    .label = try allocator.dupe(u8, label),
                    .description = try allocator.dupe(u8, desc),
                    .preview = preview,
                });
            },
            else => {},
        }
    }
}

/// Append options by splitting a delimited string on `,` `|` or newline.
fn appendLabelsFromDelimited(allocator: std.mem.Allocator, out: *std.array_list.Managed(Option), raw: []const u8) ParseError!void {
    var it = std.mem.tokenizeAny(u8, raw, ",|\n");
    while (it.next()) |tok| {
        const label = std.mem.trim(u8, tok, " \t\r\n\"'");
        if (label.len == 0) continue;
        try out.append(.{
            .label = try allocator.dupe(u8, label),
            .description = try allocator.dupe(u8, ""),
            .preview = null,
        });
    }
}

/// Serialize a multi-select answer. The reference joins selected labels with
/// ", " (AskUserQuestionTool.tsx:69-74). Caller owns the returned slice.
pub fn serializeMultiSelect(allocator: std.mem.Allocator, labels: []const []const u8) std.mem.Allocator.Error![]u8 {
    if (labels.len == 0) return allocator.dupe(u8, "");
    var total: usize = 0;
    for (labels) |l| total += l.len;
    total += (labels.len - 1) * 2; // ", " separators
    var buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    for (labels, 0..) |l, idx| {
        if (idx > 0) {
            buf[i] = ',';
            buf[i + 1] = ' ';
            i += 2;
        }
        @memcpy(buf[i .. i + l.len], l);
        i += l.len;
    }
    return buf;
}

// --- internal helpers ---

/// Extract the best user-facing label from an option object. Prefers `label`
/// (the reference canonical key) then falls back to common alternates so models
/// trained on adjacent schemas still produce usable options.
fn extractLabel(obj: std.json.ObjectMap) ?[]const u8 {
    const keys = [_][]const u8{ "label", "text", "value", "title", "content", "name" };
    for (keys) |key| {
        if (obj.get(key)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return null;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    return null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) bool {
    if (obj.get(key)) |v| {
        if (v == .bool) return v.bool;
    }
    return false;
}

/// Dupe a header truncated to MAX_HEADER_LEN characters (byte-truncation is
/// safe here: headers are short ASCII chips in practice; we avoid splitting a
/// trailing multi-byte sequence by clamping to the last whole UTF-8 boundary).
fn dupTruncatedHeader(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    if (raw.len <= MAX_HEADER_LEN) return allocator.dupe(u8, raw);
    var end: usize = MAX_HEADER_LEN;
    // Back off to avoid cutting a UTF-8 continuation byte mid-sequence.
    while (end > 0 and (raw[end] & 0xC0) == 0x80) : (end -= 1) {}
    return allocator.dupe(u8, raw[0..end]);
}

fn freeOptions(allocator: std.mem.Allocator, options: []Option) void {
    freeOptionList(allocator, options);
    allocator.free(options);
}

fn freeOptionList(allocator: std.mem.Allocator, options: []const Option) void {
    for (options) |opt| {
        allocator.free(opt.label);
        allocator.free(opt.description);
        if (opt.preview) |p| allocator.free(p);
    }
}

fn freeQuestion(allocator: std.mem.Allocator, q: Question) void {
    allocator.free(q.question);
    allocator.free(q.header);
    freeOptions(allocator, q.options);
}

// --- tests ---

const testing = std.testing;

test "parseQuestions parses 2-question payload with rich options" {
    const input =
        \\{"questions":[
        \\  {"question":"Pick a color","header":"Color","options":[
        \\    {"label":"Red","description":"warm","preview":"#ff0000"},
        \\    {"label":"Blue","description":"cool"}
        \\  ]},
        \\  {"question":"Pick toppings","header":"Toppings","multiSelect":true,"options":[
        \\    {"label":"Cheese"},
        \\    {"label":"Mushroom","description":"earthy"},
        \\    {"label":"Olive"}
        \\  ]}
        \\]}
    ;
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();

    try testing.expectEqual(@as(usize, 2), qs.items.len);

    const q0 = qs.items[0];
    try testing.expectEqualStrings("Pick a color", q0.question);
    try testing.expectEqualStrings("Color", q0.header);
    try testing.expectEqual(false, q0.multi_select);
    try testing.expectEqual(@as(usize, 2), q0.options.len);
    try testing.expectEqualStrings("Red", q0.options[0].label);
    try testing.expectEqualStrings("warm", q0.options[0].description);
    try testing.expect(q0.options[0].preview != null);
    try testing.expectEqualStrings("#ff0000", q0.options[0].preview.?);
    // Second option has no preview.
    try testing.expect(q0.options[1].preview == null);
    try testing.expectEqualStrings("cool", q0.options[1].description);

    const q1 = qs.items[1];
    try testing.expectEqualStrings("Pick toppings", q1.question);
    try testing.expectEqualStrings("Toppings", q1.header);
    try testing.expectEqual(true, q1.multi_select);
    try testing.expectEqual(@as(usize, 3), q1.options.len);
    try testing.expectEqualStrings("Mushroom", q1.options[1].label);
    try testing.expectEqualStrings("earthy", q1.options[1].description);
}

test "parseQuestions back-compat: legacy question+choices string array" {
    const input = "{\"question\":\"Continue?\",\"choices\":\"[\\\"a\\\",\\\"b\\\"]\"}";
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();

    try testing.expectEqual(@as(usize, 1), qs.items.len);
    try testing.expectEqualStrings("Continue?", qs.items[0].question);
    try testing.expectEqualStrings("", qs.items[0].header);
    try testing.expectEqual(false, qs.items[0].multi_select);
    try testing.expectEqual(@as(usize, 2), qs.items[0].options.len);
    try testing.expectEqualStrings("a", qs.items[0].options[0].label);
    try testing.expectEqualStrings("b", qs.items[0].options[1].label);
}

test "parseQuestions back-compat: legacy choices as actual JSON array" {
    const input = "{\"question\":\"Pick\",\"choices\":[\"yes\",\"no\",\"maybe\"]}";
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();
    try testing.expectEqual(@as(usize, 1), qs.items.len);
    try testing.expectEqual(@as(usize, 3), qs.items[0].options.len);
    try testing.expectEqualStrings("yes", qs.items[0].options[0].label);
}

test "parseQuestions back-compat: legacy delimited choices string" {
    const input = "{\"question\":\"Pick\",\"choices\":\"yes | no | maybe\"}";
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();
    try testing.expectEqual(@as(usize, 3), qs.items[0].options.len);
    try testing.expectEqualStrings("maybe", qs.items[0].options[2].label);
}

test "serializeMultiSelect joins labels with comma-space" {
    const labels = [_][]const u8{ "a", "b" };
    const out = try serializeMultiSelect(testing.allocator, &labels);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a, b", out);
}

test "serializeMultiSelect single label has no separator" {
    const labels = [_][]const u8{"only"};
    const out = try serializeMultiSelect(testing.allocator, &labels);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("only", out);
}

test "serializeMultiSelect three labels" {
    const labels = [_][]const u8{ "Cheese", "Mushroom", "Olive" };
    const out = try serializeMultiSelect(testing.allocator, &labels);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Cheese, Mushroom, Olive", out);
}

test "parseQuestions rejects a question with fewer than 2 options" {
    const input =
        \\{"questions":[{"question":"q","options":[{"label":"only"}]}]}
    ;
    try testing.expectError(error.TooFewOptions, parseQuestions(testing.allocator, input));
}

test "parseQuestions caps options at 4 and questions at 4" {
    const input =
        \\{"questions":[
        \\  {"question":"q1","options":[{"label":"a"},{"label":"b"},{"label":"c"},{"label":"d"},{"label":"e"}]},
        \\  {"question":"q2","options":[{"label":"a"},{"label":"b"}]},
        \\  {"question":"q3","options":[{"label":"a"},{"label":"b"}]},
        \\  {"question":"q4","options":[{"label":"a"},{"label":"b"}]},
        \\  {"question":"q5","options":[{"label":"a"},{"label":"b"}]}
        \\]}
    ;
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();
    try testing.expectEqual(@as(usize, 4), qs.items.len); // capped at MAX_QUESTIONS
    try testing.expectEqual(@as(usize, 4), qs.items[0].options.len); // capped at MAX_OPTIONS
}

test "parseQuestions truncates header to 12 chars" {
    const input =
        \\{"questions":[{"question":"q","header":"ThisIsAReallyLongHeader","options":[{"label":"a"},{"label":"b"}]}]}
    ;
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();
    try testing.expectEqual(@as(usize, MAX_HEADER_LEN), qs.items[0].header.len);
    try testing.expectEqualStrings("ThisIsAReal", qs.items[0].header[0..11]);
}

test "parseQuestions returns NoQuestions for non-object payload" {
    try testing.expectError(error.NoQuestions, parseQuestions(testing.allocator, "not json"));
    try testing.expectError(error.NoQuestions, parseQuestions(testing.allocator, "[]"));
    try testing.expectError(error.NoQuestions, parseQuestions(testing.allocator, "{\"unrelated\":1}"));
}

test "parseQuestions tolerates plain-string options under rich schema" {
    const input =
        \\{"questions":[{"question":"q","options":["a","b","c"]}]}
    ;
    var qs = try parseQuestions(testing.allocator, input);
    defer qs.deinit();
    try testing.expectEqual(@as(usize, 3), qs.items[0].options.len);
    try testing.expectEqualStrings("a", qs.items[0].options[0].label);
    try testing.expectEqualStrings("", qs.items[0].options[0].description);
}
