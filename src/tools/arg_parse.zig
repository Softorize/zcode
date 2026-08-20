const std = @import("std");

pub fn parseBool(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}

pub fn parseUsize(v: ?[]const u8, fallback: usize) usize {
    const raw = v orelse return fallback;
    return std.fmt.parseInt(usize, raw, 10) catch fallback;
}

pub fn getArg(input_args: []const u8, key: []const u8) ?[]const u8 {
    return getArgDepth(input_args, key, 0);
}

fn getArgDepth(input_args: []const u8, key: []const u8, depth: usize) ?[]const u8 {
    var i: usize = 0;
    while (i < input_args.len) {
        while (i < input_args.len and (input_args[i] == ';' or input_args[i] == ',' or input_args[i] == '\n' or std.ascii.isWhitespace(input_args[i]))) : (i += 1) {}
        if (i >= input_args.len) break;

        const start = i;
        var nesting: usize = 0;
        var in_string = false;
        var quote: u8 = 0;
        scan: while (i < input_args.len) : (i += 1) {
            const ch = input_args[i];
            if (in_string) {
                if (ch == '\\' and i + 1 < input_args.len) {
                    i += 1;
                    continue;
                }
                if (ch == quote) {
                    in_string = false;
                    quote = 0;
                }
                continue;
            }

            switch (ch) {
                '"', '\'' => {
                    in_string = true;
                    quote = ch;
                },
                '[', '{', '(' => nesting += 1,
                ']', '}', ')' => {
                    if (nesting > 0) nesting -= 1;
                },
                ';', ',', '\n' => {
                    if (nesting == 0) break :scan;
                },
                else => {},
            }
        }

        // Recovery path: if an unclosed quote swallowed the rest of the input,
        // the scan above will have walked all the way to the end and every
        // subsequent `,`/`;` was ignored. Rewind to `start` and find the real
        // top-level separator without string handling so later keys remain
        // discoverable. Without this, a malformed payload like
        // `name="unclosed, model=gpt-4` would make `model` silently unfindable.
        if (in_string and i == input_args.len) {
            i = start;
            var recover_nest: usize = 0;
            while (i < input_args.len) : (i += 1) {
                const ch = input_args[i];
                switch (ch) {
                    '[', '{', '(' => recover_nest += 1,
                    ']', '}', ')' => {
                        if (recover_nest > 0) recover_nest -= 1;
                    },
                    ';', ',', '\n' => {
                        if (recover_nest == 0) break;
                    },
                    else => {},
                }
            }
        }

        const pair = std.mem.trim(u8, input_args[start..i], " \t");
        const sep = std.mem.indexOfScalar(u8, pair, '=') orelse std.mem.indexOfScalar(u8, pair, ':') orelse {
            if (i < input_args.len) i += 1;
            continue;
        };
        const k = std.mem.trim(u8, pair[0..sep], " \t\"'");
        const v = trimOuterQuotes(std.mem.trim(u8, pair[sep + 1 ..], " \t"));
        if (std.mem.eql(u8, k, key)) return v;
        if (depth < 4 and isArgumentContainerKey(k)) {
            if (unwrapObjectBody(v)) |nested| {
                if (getArgDepth(nested, key, depth + 1)) |nested_match| return nested_match;
            }
        }

        if (i < input_args.len and (input_args[i] == ';' or input_args[i] == ',' or input_args[i] == '\n')) i += 1;
    }
    return null;
}

fn trimOuterQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn unwrapObjectBody(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return trimmed[1 .. trimmed.len - 1];
    }

    const unquoted = trimOuterQuotes(trimmed);
    if (unquoted.len >= 2 and unquoted[0] == '{' and unquoted[unquoted.len - 1] == '}') {
        return unquoted[1 .. unquoted.len - 1];
    }

    return null;
}

fn isArgumentContainerKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "args") or
        std.mem.eql(u8, key, "arguments") or
        std.mem.eql(u8, key, "payload") or
        std.mem.eql(u8, key, "parameters") or
        std.mem.eql(u8, key, "input") or
        std.mem.eql(u8, key, "schema");
}

const testing = std.testing;

test "parse key value args" {
    try testing.expectEqualStrings("src/main.zig", getArg("path=src/main.zig;append=false", "path").?);
    try testing.expectEqualStrings("[\"Approve\",\"Discuss\"]", getArg("question=\"Continue?\",choices=[\"Approve\",\"Discuss\"]", "choices").?);
    try testing.expectEqualStrings("README.md", getArg("\"path\":\"README.md\", \"max_bytes\":1024", "path").?);
    try testing.expectEqualStrings("ollama --version", getArg("schema={\"command\":\"ollama --version\",\"timeout_seconds\":10}", "command").?);
    try testing.expectEqualStrings("ls", getArg("args={\"schema\":{\"command\":\"ls\"}}", "command").?);
    try testing.expect(getArg("x=1", "missing") == null);
}

test "unclosed quote recovery lets later args parse" {
    // Without the recovery pass, the unclosed `"` in the first pair would
    // swallow the rest of the input and `model`/`other` would be invisible.
    const input = "name=\"unclosed, model=gpt-4, other=x";
    try testing.expectEqualStrings("gpt-4", getArg(input, "model").?);
    try testing.expectEqualStrings("x", getArg(input, "other").?);
}
