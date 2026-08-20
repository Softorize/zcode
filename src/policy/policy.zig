const std = @import("std");
const rt = @import("zcode_runtime");
const types = @import("../core/types.zig");

pub const Policy = struct {
    allocator: std.mem.Allocator,
    default_approval_mode: []u8,
    allow_network: bool,
    block_destructive_shell: bool,
    blocked_tools: std.StringHashMap(void),
    blocked_shell_patterns: std.StringHashMap(void),
    unknown_keys: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) !Policy {
        return .{
            .allocator = allocator,
            .default_approval_mode = try allocator.dupe(u8, "tiered-auto"),
            .allow_network = true,
            .block_destructive_shell = true,
            .blocked_tools = std.StringHashMap(void).init(allocator),
            .blocked_shell_patterns = std.StringHashMap(void).init(allocator),
            .unknown_keys = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Policy) void {
        self.allocator.free(self.default_approval_mode);

        var it = self.blocked_tools.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.blocked_tools.deinit();

        var shell_it = self.blocked_shell_patterns.keyIterator();
        while (shell_it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.blocked_shell_patterns.deinit();

        var unknown_it = self.unknown_keys.keyIterator();
        while (unknown_it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.unknown_keys.deinit();
    }

    pub fn loadFromFile(self: *Policy, path: []const u8) !bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(512 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            try self.parseLine(raw_line);
        }

        return true;
    }

    fn parseLine(self: *Policy, raw_line: []const u8) !void {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) return;
        if (line[0] == '#') return;
        if (line[0] == '[') return;

        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        var value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
        value = stripTrailingComment(value);
        value = std.mem.trimEnd(u8, value, " \t");
        value = stripQuotes(value);
        if (key.len == 0) return error.InvalidPolicyKey;
        if (containsControlByte(key) or containsControlByte(value)) return error.InvalidPolicyValue;

        if (std.mem.eql(u8, key, "default_approval_mode")) {
            const next_mode = try self.allocator.dupe(u8, value);
            self.allocator.free(self.default_approval_mode);
            self.default_approval_mode = next_mode;
        } else if (std.mem.eql(u8, key, "allow_network")) {
            self.allow_network = try parseBoolStrict(value);
        } else if (std.mem.eql(u8, key, "block_destructive_shell")) {
            self.block_destructive_shell = try parseBoolStrict(value);
        } else if (std.mem.eql(u8, key, "blocked_tool")) {
            if (value.len == 0) return error.InvalidBlockedTool;
            try putUniqueKey(self.allocator, &self.blocked_tools, value);
        } else if (std.mem.eql(u8, key, "blocked_shell_pattern")) {
            if (std.mem.trim(u8, value, " \t").len == 0) return error.InvalidBlockedShellPattern;
            try putUniqueKey(self.allocator, &self.blocked_shell_patterns, value);
        } else {
            try putUniqueKey(self.allocator, &self.unknown_keys, key);
        }
    }

    pub fn classifyTool(self: *const Policy, tool_name: []const u8, args: []const u8) types.RiskTier {
        if (self.blocked_tools.contains(tool_name)) {
            return .BLOCKED;
        }

        if (matchesToolName(tool_name, &.{ "TaskRun", "task_run" })) {
            return .HIGH;
        }

        if (matchesToolName(tool_name, &.{ "Task", "task" }) and taskActionIsRun(args)) {
            return .HIGH;
        }

        if (matchesToolName(tool_name, &.{
            "file_read",                   "Read",               "read",
            "git_status",                  "Glob",               "glob",
            "Grep",                        "grep",               "TaskGet",
            "task_get",                    "TaskList",           "task_list",
            "TaskOutput",                  "task_output",        "Skill",
            "skill",                       "Command",            "command",
            "AskUserQuestion",             "ask_user_question",  "EnterPlanMode",
            "enter_plan_mode",             "ExitPlanMode",       "exit_plan_mode",
            "ListDir",                     "list_dir",           "Stat",
            "stat",                        "GitDiff",            "git_diff",
            "GitLog",                      "git_log",            "TaskPoll",
            "task_poll",                   "JsonQuery",          "json_query",
            "mcp_servers_list",            "McpServersList",     "mcp_tools_list",
            "McpToolsList",                "mcp_resources_list", "mcp_resource_read",
            "mcp_resource_templates_list", "mcp_prompts_list",   "mcp_prompt_get",
            "mcp_notifications",           "mcp_complete",       "Sleep",
            "sleep",
        })) {
            return .LOW;
        }

        if (matchesToolName(tool_name, &.{
            "file_write",   "Write",         "write",
            "file_edit",    "Edit",          "edit",
            "NotebookEdit", "notebook_edit", "git_apply",
            "GitApply",     "TaskCreate",    "task_create",
            "TaskUpdate",   "task_update",   "TaskStop",
            "task_stop",    "Task",          "task",
            "TeamCreate",   "team_create",   "TeamDelete",
            "team_delete",  "SendMessage",   "send_message",
            "Move",         "move",          "Copy",
            "copy",         "RunTests",      "run_tests",
            "GitCommit",    "git_commit",
        })) {
            return .MEDIUM;
        }

        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" })) {
            var shell_it = self.blocked_shell_patterns.keyIterator();
            while (shell_it.next()) |pattern| {
                if (std.mem.indexOf(u8, args, pattern.*) != null) return .BLOCKED;
            }

            if (self.block_destructive_shell and isDestructiveShell(args)) {
                return .HIGH;
            }
            return .MEDIUM;
        }

        if (matchesToolName(tool_name, &.{ "Delete", "delete" })) {
            return .HIGH;
        }

        // Phase 9 Task 8 (tools-07): Config tool. A read (no `value` arg) is
        // read-only and auto-allowed at LOW, mirroring the reference's
        // isReadOnly auto-allow (ConfigTool.ts:90-107). A write (`value`
        // present) is a mutating action and routes through the normal approval
        // path at HIGH.
        if (matchesToolName(tool_name, &.{ "Config", "config" })) {
            if (parseArgValue(args, "value") == null) return .LOW;
            return .HIGH;
        }

        if (matchesToolName(tool_name, &.{
            "WebFetch",    "web_fetch",
            "WebSearch",   "web_search",
            "HttpRequest", "http_request",
            "OpenPR",      "open_pr",
        })) {
            if (!self.allow_network) return .BLOCKED;
            // Preapproved-host shortcut for WebFetch: documentation
            // sites (docs.python.org, react.dev, MDN, ...) are
            // GET-only targets that the reference auto-approves
            // via src/tools/WebFetchTool/preapproved.ts. Without
            // this downgrade, every `WebFetch docs.python.org/3/`
            // call in a docs-heavy session interrupts the user
            // with an approval prompt, even though the fetch is
            // as safe as a Grep on a checked-in source file.
            //
            // Only applies to WebFetch -- WebSearch hits the
            // DuckDuckGo API (no host to preapprove), and
            // HttpRequest/OpenPR are method-agnostic so we keep
            // them at HIGH.
            if (matchesToolName(tool_name, &.{ "WebFetch", "web_fetch" })) {
                const web_preapproved = @import("../core/web_preapproved.zig");
                if (extractWebFetchUrl(args)) |url| {
                    if (web_preapproved.isPreapprovedUrl(url)) return .LOW;
                }
            }
            return .HIGH;
        }

        if (std.mem.eql(u8, tool_name, "mcp_invoke")) {
            if (!self.allow_network) return .BLOCKED;
            return .HIGH;
        }

        if (std.mem.startsWith(u8, tool_name, "mcp::")) {
            if (!self.allow_network) return .BLOCKED;
            return .HIGH;
        }

        if (std.mem.eql(u8, tool_name, "network") and !self.allow_network) {
            return .BLOCKED;
        }

        return .HIGH;
    }

    pub fn requiresApproval(self: *const Policy, tier: types.RiskTier) bool {
        _ = self;
        return switch (tier) {
            .LOW => false,
            .MEDIUM => false,
            .HIGH => true,
            .BLOCKED => false,
        };
    }

    pub fn print(self: *const Policy, writer: anytype) !void {
        try writer.print("default_approval_mode = {s}\n", .{self.default_approval_mode});
        try writer.print("allow_network = {}\n", .{self.allow_network});
        try writer.print("block_destructive_shell = {}\n", .{self.block_destructive_shell});

        var it = self.blocked_tools.keyIterator();
        while (it.next()) |k| {
            try writer.print("blocked_tool = {s}\n", .{k.*});
        }

        var shell_it = self.blocked_shell_patterns.keyIterator();
        while (shell_it.next()) |k| {
            try writer.print("blocked_shell_pattern = {s}\n", .{k.*});
        }

        var unknown_it = self.unknown_keys.keyIterator();
        while (unknown_it.next()) |k| {
            try writer.print("unknown_key = {s}\n", .{k.*});
        }
    }

    pub fn validate(self: *const Policy) !void {
        if (!std.mem.eql(u8, self.default_approval_mode, "tiered-auto") and
            !std.mem.eql(u8, self.default_approval_mode, "manual") and
            !std.mem.eql(u8, self.default_approval_mode, "strict"))
        {
            return error.InvalidApprovalMode;
        }

        if (self.unknown_keys.count() > 0) {
            return error.UnknownPolicyKey;
        }

        var shell_it = self.blocked_shell_patterns.keyIterator();
        while (shell_it.next()) |pattern| {
            if (std.mem.trim(u8, pattern.*, " \t").len == 0) return error.InvalidBlockedShellPattern;
        }

        var tool_it = self.blocked_tools.keyIterator();
        while (tool_it.next()) |tool| {
            if (!isKnownToolName(tool.*)) return error.InvalidBlockedTool;
        }
    }
};

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn stripTrailingComment(value: []const u8) []const u8 {
    var in_quote = false;
    var quote: u8 = 0;
    var escaped = false;
    for (value, 0..) |c, idx| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_quote) {
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == quote) {
                in_quote = false;
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_quote = true;
            quote = c;
            continue;
        }
        if (c == '#') return std.mem.trimEnd(u8, value[0..idx], " \t");
    }
    return value;
}

fn containsControlByte(value: []const u8) bool {
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

fn parseBoolStrict(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "no")) return false;
    return error.InvalidPolicyBool;
}

fn isDestructiveShell(args: []const u8) bool {
    const bash_security = @import("../tools/bash_security.zig");
    const arg_parse = @import("../tools/arg_parse.zig");
    const command = arg_parse.getArg(args, "command") orelse args;
    return bash_security.isDestructive(command);
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn taskActionIsRun(args: []const u8) bool {
    const action = parseArgValue(args, "action") orelse return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, action, " \t\"'"), "run");
}

/// Pull the `url` argument out of a WebFetch tool-call args blob so
/// the preapproved-host classifier can peek at the target hostname.
/// Returns null when no url field is present (the tool will then
/// fail its own validation anyway; we just let it through at HIGH
/// risk so the regular approval flow kicks in).
fn extractWebFetchUrl(args: []const u8) ?[]const u8 {
    const raw = parseArgValue(args, "url") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\"'");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn parseArgValue(args: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and (args[i] == ';' or args[i] == ',' or args[i] == '\n' or std.ascii.isWhitespace(args[i]))) : (i += 1) {}
        if (i >= args.len) break;

        const start = i;
        var depth: usize = 0;
        var in_string = false;
        var quote: u8 = 0;
        scan: while (i < args.len) : (i += 1) {
            const ch = args[i];
            if (in_string) {
                if (ch == '\\' and i + 1 < args.len) {
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
                '[', '{', '(' => depth += 1,
                ']', '}', ')' => {
                    if (depth > 0) depth -= 1;
                },
                ';', ',', '\n' => {
                    if (depth == 0) break :scan;
                },
                else => {},
            }
        }

        const pair = std.mem.trim(u8, args[start..i], " \t");
        const sep = std.mem.indexOfScalar(u8, pair, '=') orelse std.mem.indexOfScalar(u8, pair, ':') orelse {
            if (i < args.len) i += 1;
            continue;
        };
        const k = std.mem.trim(u8, pair[0..sep], " \t\"'");
        var v = std.mem.trim(u8, pair[sep + 1 ..], " \t");
        if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
            v = v[1 .. v.len - 1];
        }
        if (std.mem.eql(u8, k, key)) return v;

        if (i < args.len and (args[i] == ';' or args[i] == ',' or args[i] == '\n')) i += 1;
    }
    return null;
}

fn isKnownToolName(name: []const u8) bool {
    if (matchesToolName(name, &.{
        "shell",           "Bash",              "bash",
        "file_read",       "Read",              "read",
        "file_write",      "Write",             "write",
        "file_edit",       "Edit",              "edit",
        "git_status",      "git_apply",         "GitApply",
        "mcp_invoke",      "Glob",              "glob",
        "Grep",            "grep",              "WebFetch",
        "web_fetch",       "WebSearch",         "web_search",
        "NotebookEdit",    "notebook_edit",     "Task",
        "task",            "TaskCreate",        "task_create",
        "TaskGet",         "task_get",          "TaskUpdate",
        "task_update",     "TaskList",          "task_list",
        "TaskStop",        "task_stop",         "TaskOutput",
        "task_output",     "TaskRun",           "task_run",
        "TaskPoll",        "task_poll",         "Skill",
        "skill",           "Command",           "command",
        "AskUserQuestion", "ask_user_question", "EnterPlanMode",
        "enter_plan_mode", "ExitPlanMode",      "exit_plan_mode",
        "TeamCreate",      "team_create",       "TeamDelete",
        "team_delete",     "SendMessage",       "send_message",
        "Move",            "move",              "Copy",
        "copy",            "Delete",            "delete",
        "ListDir",         "list_dir",          "Stat",
        "stat",            "RunTests",          "run_tests",
        "OpenPR",          "open_pr",           "GitCommit",
        "git_commit",      "GitDiff",           "git_diff",
        "GitLog",          "git_log",           "HttpRequest",
        "http_request",    "JsonQuery",         "json_query",
        "Config",          "config",            "network",
    })) return true;
    if (std.mem.startsWith(u8, name, "mcp::")) return true;
    return false;
}

fn matchesToolName(name: []const u8, set: []const []const u8) bool {
    for (set) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn putUniqueKey(allocator: std.mem.Allocator, map: *std.StringHashMap(void), key: []const u8) !void {
    if (map.contains(key)) return;
    const dup = try allocator.dupe(u8, key);
    try map.put(dup, {});
}

const testing = std.testing;

test "classify destructive shell as high" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try testing.expect(p.classifyTool("shell", "rm -rf /") == .HIGH);
}

test "unknown policy key fails validation" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try p.parseLine("not_a_real_key = true");
    try testing.expectError(error.UnknownPolicyKey, p.validate());
}

test "policy bools are strict and comments are stripped" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try p.parseLine("allow_network = no # staged rollout");
    try testing.expect(!p.allow_network);
    try p.parseLine("block_destructive_shell = yes");
    try testing.expect(p.block_destructive_shell);
    try testing.expectError(error.InvalidPolicyBool, p.parseLine("allow_network = maybe"));
}

test "policy rejects control bytes and empty entries" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try testing.expectError(error.InvalidPolicyValue, p.parseLine("blocked_tool = \"Write\x1b\""));
    try testing.expectError(error.InvalidBlockedTool, p.parseLine("blocked_tool = \"\""));
    try testing.expectError(error.InvalidBlockedShellPattern, p.parseLine("blocked_shell_pattern = \"\""));
}

test "task run is high risk" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try testing.expect(p.classifyTool("TaskRun", "command=echo hi") == .HIGH);
    try testing.expect(p.classifyTool("Task", "action=run;command=echo hi") == .HIGH);
    try testing.expect(p.classifyTool("Task", "action=runner;command=echo hi") == .MEDIUM);
}

test "WebFetch against a preapproved host is downgraded to LOW" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    // Docs sites should auto-approve
    try testing.expect(p.classifyTool("WebFetch", "url=https://docs.python.org/3/") == .LOW);
    try testing.expect(p.classifyTool("WebFetch", "url=https://react.dev/learn") == .LOW);
    try testing.expect(p.classifyTool("WebFetch", "url=https://pkg.go.dev/net/http") == .LOW);

    // Unknown hosts stay HIGH
    try testing.expect(p.classifyTool("WebFetch", "url=https://evil.example.com/exfil") == .HIGH);
    try testing.expect(p.classifyTool("WebFetch", "url=https://pastebin.com/raw/abc") == .HIGH);
}

test "WebFetch with malformed url falls back to HIGH" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try testing.expect(p.classifyTool("WebFetch", "") == .HIGH);
    try testing.expect(p.classifyTool("WebFetch", "path=/etc/passwd") == .HIGH);
}

test "Config read is LOW (auto-allow) and Config write is HIGH (ask)" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    // Read: no `value` arg -> read-only, auto-allowed.
    try testing.expect(p.classifyTool("Config", "setting=theme") == .LOW);
    try testing.expect(p.classifyTool("Config", "\"setting\":\"theme\"") == .LOW);
    try testing.expect(p.classifyTool("config", "setting=model") == .LOW);

    // Write: `value` present -> mutating, routes through approval.
    try testing.expect(p.classifyTool("Config", "setting=theme,value=light") == .HIGH);
    try testing.expect(p.classifyTool("Config", "\"setting\":\"theme\", \"value\":\"light\"") == .HIGH);
}

test "WebFetch preapproved downgrade does not apply to WebSearch/HttpRequest" {
    // Only WebFetch gets the host-based downgrade. WebSearch hits
    // the DuckDuckGo API (no host to preapprove) and HttpRequest
    // is method-agnostic so they stay HIGH.
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();

    try testing.expect(p.classifyTool("WebSearch", "query=docs python") == .HIGH);
    try testing.expect(p.classifyTool("HttpRequest", "url=https://docs.python.org/3/") == .HIGH);
}

test "WebFetch preapproved is still blocked when allow_network is off" {
    const allocator = testing.allocator;
    var p = try Policy.init(allocator);
    defer p.deinit();
    p.allow_network = false;

    // The preapproved list is a LOW/HIGH downgrade, NOT a network
    // policy override. allow_network=false still wins.
    try testing.expect(p.classifyTool("WebFetch", "url=https://docs.python.org/3/") == .BLOCKED);
}
