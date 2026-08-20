const std = @import("std");
const std_io = @import("std_io.zig");

pub const LenientParsedJson = struct {
    value: std.json.Parsed(std.json.Value),
    normalized_input: ?[]u8 = null,

    pub fn deinit(self: *LenientParsedJson, allocator: std.mem.Allocator) void {
        self.value.deinit();
        if (self.normalized_input) |buf| allocator.free(buf);
    }
};

pub fn parseJsonLenient(allocator: std.mem.Allocator, candidate: []const u8) !?LenientParsedJson {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, candidate, .{}) catch {
        const normalized = (try normalizeJsLikeJson(allocator, candidate)) orelse return null;
        const reparsed = std.json.parseFromSlice(std.json.Value, allocator, normalized, .{}) catch {
            allocator.free(normalized);
            return null;
        };
        return .{
            .value = reparsed,
            .normalized_input = normalized,
        };
    };

    return .{
        .value = parsed,
        .normalized_input = null,
    };
}

pub fn normalizeJsLikeJson(allocator: std.mem.Allocator, input: []const u8) !?[]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var changed = false;
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];

        if (ch == '"') {
            try out.append(ch);
            i += 1;

            var escape = false;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                try out.append(c);

                if (escape) {
                    escape = false;
                    continue;
                }
                if (c == '\\') {
                    escape = true;
                    continue;
                }
                if (c == '"') {
                    i += 1;
                    break;
                }
            }
            continue;
        }

        if (ch == '\'') {
            changed = true;
            try out.append('"');
            i += 1;

            var escape = false;
            while (i < input.len) : (i += 1) {
                const c = input[i];
                if (escape) {
                    if (c == '"') {
                        try out.append('\\');
                        try out.append('"');
                    } else if (c == '\'') {
                        try out.append('\'');
                    } else {
                        try out.append('\\');
                        try out.append(c);
                    }
                    escape = false;
                    continue;
                }

                if (c == '\\') {
                    escape = true;
                    continue;
                }
                if (c == '\'') break;

                if (c == '"') {
                    try out.append('\\');
                    try out.append('"');
                } else {
                    try out.append(c);
                }
            }

            if (i >= input.len) return null;
            try out.append('"');
            i += 1;
            continue;
        }

        if (isIdentifierStart(ch)) {
            var j = i + 1;
            while (j < input.len and isIdentifierChar(input[j])) : (j += 1) {}
            var k = j;
            while (k < input.len and std.ascii.isWhitespace(input[k])) : (k += 1) {}
            const prev = lastSignificantByte(out.items());
            if (k < input.len and input[k] == ':' and (prev == null or prev.? == '{' or prev.? == ',')) {
                changed = true;
                try out.append('"');
                try out.appendSlice(input[i..j]);
                try out.append('"');
                i = j;
                continue;
            }
        }

        try out.append(ch);
        i += 1;
    }

    if (!changed) return null;
    return try out.toOwnedSlice();
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
}

fn lastSignificantByte(text: []const u8) ?u8 {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) continue;
        return ch;
    }
    return null;
}

const testing = std.testing;
test "parseJsonLenient parses valid json" {
    const alloc = testing.allocator;
    var result = (try parseJsonLenient(alloc, "{\"a\":1}")).?;
    defer result.deinit(alloc);
    try testing.expect(result.value.value == .object);
}
test "parseJsonLenient returns null for garbage" {
    try testing.expect((try parseJsonLenient(testing.allocator, "not json")) == null);
}

test "normalizeJsLikeJson returns null when input is already valid JSON" {
    // Strictly-valid input carries no single-quoted strings or
    // identifier keys, so the normaliser has no work to do and
    // signals that by returning null.
    const res = try normalizeJsLikeJson(testing.allocator, "{\"k\":1}");
    try testing.expect(res == null);
}

test "normalizeJsLikeJson converts single quotes to double quotes" {
    const res = try normalizeJsLikeJson(testing.allocator, "{'k':'v'}");
    try testing.expect(res != null);
    defer testing.allocator.free(res.?);
    try testing.expectEqualStrings("{\"k\":\"v\"}", res.?);
}

test "normalizeJsLikeJson preserves double-quoted strings that contain apostrophes" {
    // A real-world LLM quirk: emit double-quoted keys but let an
    // apostrophe slip inside a value. The normaliser must not
    // rewrite the apostrophe inside "don't".
    const res = try normalizeJsLikeJson(testing.allocator, "{\"msg\":\"don't stop\"}");
    // Already valid -> null expected.
    try testing.expect(res == null);
}

test "normalizeJsLikeJson escapes embedded double quotes when rewriting single-quoted strings" {
    // Input:  {'msg':'she said \"hi\"'}
    // Output: {"msg":"she said \"hi\""}
    const input = "{'msg':'she said \\\"hi\\\"'}";
    const res = try normalizeJsLikeJson(testing.allocator, input);
    try testing.expect(res != null);
    defer testing.allocator.free(res.?);
    try testing.expect(std.mem.indexOf(u8, res.?, "\\\"hi\\\"") != null);
}
