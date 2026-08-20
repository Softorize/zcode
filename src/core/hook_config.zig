//! P3 (PRD #534) hook configuration. Parses Claude Code's settings.json `hooks`
//! map into a flat list of normalized hook definitions. Shape:
//!
//!   { "hooks": { "PreToolUse": [ { "matcher": "Bash(git *)",
//!       "hooks": [ {"type":"command","command":"./x.sh","timeout":5} ] } ] } }
//!
//! Returned strings borrow from the owned parsed value; keep `Parsed` alive.

const std = @import("std");
const hook_event = @import("hook_event.zig");

pub const HookType = enum { command, prompt, http, agent };

pub const HookDef = struct {
    event: hook_event.Event,
    matcher: []const u8 = "*",
    hook_type: HookType,
    /// command (command type), prompt text (prompt/agent), or url (http).
    body: []const u8 = "",
    model: []const u8 = "",
    timeout_s: ?u32 = null,
    once: bool = false,
    is_async: bool = false,
    /// Permission-rule pre-filter (`if`), e.g. "Bash(git *)". Borrows from Parsed.
    if_cond: []const u8 = "",
    /// Shell to run a command hook under; "" means apply the "bash" default at
    /// exec time, not here. Borrows from Parsed.
    shell: []const u8 = "",
    /// Spinner status line shown while the hook runs. Borrows from Parsed.
    status_message: []const u8 = "",
    /// `asyncRewake`: background hook that wakes the model on exit code 2. Per
    /// the schema, this implies is_async.
    async_rewake: bool = false,
    /// Raw JSON object slice for http `headers` (re-serialized; owned by Parsed
    /// via headers_storage).
    headers_json: []const u8 = "",
    /// http `allowedEnvVars`: names allowed for header interpolation. Each entry
    /// borrows from Parsed.
    allowed_env_vars: []const []const u8 = &.{},
};

pub const Parsed = struct {
    value: ?std.json.Parsed(std.json.Value) = null,
    defs: []HookDef = &.{},
    /// Re-serialized http `headers` JSON objects. The `std.json.Value` does not
    /// preserve source spans, so each http hook's headers object is re-emitted
    /// here and `HookDef.headers_json` borrows from these allocations.
    headers_storage: std.ArrayList([]u8) = .empty,
    /// Owned outer slices backing each `HookDef.allowed_env_vars`. The string
    /// elements themselves borrow from `value`; only the `[][]const u8` arrays
    /// are owned here.
    env_var_storage: std.ArrayList([][]const u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Parsed) void {
        self.allocator.free(self.defs);
        for (self.headers_storage.items) |h| self.allocator.free(h);
        self.headers_storage.deinit(self.allocator);
        for (self.env_var_storage.items) |e| self.allocator.free(e);
        self.env_var_storage.deinit(self.allocator);
        if (self.value) |*v| v.deinit();
        self.value = null;
        self.defs = &.{};
    }
};

fn typeFromString(s: []const u8) ?HookType {
    if (std.mem.eql(u8, s, "command")) return .command;
    if (std.mem.eql(u8, s, "prompt")) return .prompt;
    if (std.mem.eql(u8, s, "http")) return .http;
    if (std.mem.eql(u8, s, "agent")) return .agent;
    return null;
}

fn str(v: ?std.json.Value, default: []const u8) []const u8 {
    const val = v orelse return default;
    return switch (val) {
        .string => |s| s,
        else => default,
    };
}

fn boolOr(v: ?std.json.Value, default: bool) bool {
    const val = v orelse return default;
    return switch (val) {
        .bool => |b| b,
        else => default,
    };
}

fn timeout(v: ?std.json.Value) ?u32 {
    const val = v orelse return null;
    // Range-check before the cast: an out-of-range value must be skipped (the
    // module contract), not faulted. @intCast/@intFromFloat on an out-of-u32
    // value is illegal behavior (panic in safe builds, UB in ReleaseFast).
    const max: i64 = std.math.maxInt(u32);
    return switch (val) {
        .integer => |i| if (i > 0 and i <= max) @intCast(i) else null,
        .float => |f| if (f > 0 and f <= @as(f64, @floatFromInt(max))) @intFromFloat(f) else null,
        else => null,
    };
}

/// Re-serialize a JSON value (the http `headers` object) into an owned slice and
/// stash it in `storage`. Returns the borrowed slice for HookDef.headers_json.
fn captureHeaders(allocator: std.mem.Allocator, storage: *std.ArrayList([]u8), v: std.json.Value) ![]const u8 {
    if (v != .object) return "";
    const out = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(v, .{})});
    errdefer allocator.free(out);
    try storage.append(allocator, out);
    return out;
}

/// Capture the string elements of an `allowedEnvVars` array into an owned outer
/// slice (the strings themselves borrow from the parsed value). Non-string
/// entries are skipped.
fn captureEnvVars(allocator: std.mem.Allocator, storage: *std.ArrayList([][]const u8), v: std.json.Value) ![]const []const u8 {
    if (v != .array) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    for (v.array.items) |item| {
        switch (item) {
            .string => |s| try list.append(allocator, s),
            else => {},
        }
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    const owned = try list.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    try storage.append(allocator, owned);
    return owned;
}

/// Parse settings JSON (the full settings object) into hook defs. Missing/empty
/// `hooks` yields an empty list. Malformed entries are skipped, not errors.
pub fn parse(allocator: std.mem.Allocator, settings_json: []const u8) !Parsed {
    const trimmed = std.mem.trim(u8, settings_json, " \t\r\n");
    if (trimmed.len == 0) return .{ .allocator = allocator };
    var pv = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return .{ .allocator = allocator };
    errdefer pv.deinit();

    const root = pv.value;
    if (root != .object) {
        pv.deinit();
        return .{ .allocator = allocator };
    }
    const hooks_val = root.object.get("hooks") orelse {
        pv.deinit();
        return .{ .allocator = allocator };
    };
    if (hooks_val != .object) {
        pv.deinit();
        return .{ .allocator = allocator };
    }

    var defs: std.ArrayList(HookDef) = .empty;
    errdefer defs.deinit(allocator);
    var headers_storage: std.ArrayList([]u8) = .empty;
    errdefer {
        for (headers_storage.items) |h| allocator.free(h);
        headers_storage.deinit(allocator);
    }
    var env_var_storage: std.ArrayList([][]const u8) = .empty;
    errdefer {
        for (env_var_storage.items) |e| allocator.free(e);
        env_var_storage.deinit(allocator);
    }

    var it = hooks_val.object.iterator();
    while (it.next()) |entry| {
        const event = hook_event.fromName(entry.key_ptr.*) orelse continue;
        const groups = entry.value_ptr.*;
        if (groups != .array) continue;
        for (groups.array.items) |group| {
            if (group != .object) continue;
            const matcher = str(group.object.get("matcher"), "*");
            const inner = group.object.get("hooks") orelse continue;
            if (inner != .array) continue;
            for (inner.array.items) |h| {
                if (h != .object) continue;
                const ht = typeFromString(str(h.object.get("type"), "command")) orelse continue;
                const body = switch (ht) {
                    .command => str(h.object.get("command"), ""),
                    .http => str(h.object.get("url"), ""),
                    .prompt, .agent => str(h.object.get("prompt"), ""),
                };
                // `asyncRewake` implies `async` per schemas/hooks.ts:63.
                const async_rewake = boolOr(h.object.get("asyncRewake"), false);
                const is_async = boolOr(h.object.get("async"), false) or async_rewake;
                const headers_json = if (ht == .http and h.object.get("headers") != null)
                    try captureHeaders(allocator, &headers_storage, h.object.get("headers").?)
                else
                    "";
                const allowed_env_vars = if (ht == .http and h.object.get("allowedEnvVars") != null)
                    try captureEnvVars(allocator, &env_var_storage, h.object.get("allowedEnvVars").?)
                else
                    &.{};
                try defs.append(allocator, .{
                    .event = event,
                    .matcher = matcher,
                    .hook_type = ht,
                    .body = body,
                    .model = str(h.object.get("model"), ""),
                    .timeout_s = timeout(h.object.get("timeout")),
                    .once = boolOr(h.object.get("once"), false),
                    .is_async = is_async,
                    .if_cond = str(h.object.get("if"), ""),
                    .shell = str(h.object.get("shell"), ""),
                    .status_message = str(h.object.get("statusMessage"), ""),
                    .async_rewake = async_rewake,
                    .headers_json = headers_json,
                    .allowed_env_vars = allowed_env_vars,
                });
            }
        }
    }

    return .{
        .value = pv,
        .defs = try defs.toOwnedSlice(allocator),
        .headers_storage = headers_storage,
        .env_var_storage = env_var_storage,
        .allocator = allocator,
    };
}

const testing = std.testing;

test "parse extracts defs across events and types" {
    const json =
        \\{"hooks":{
        \\ "PreToolUse":[{"matcher":"Bash(git *)","hooks":[{"type":"command","command":"./pre.sh","timeout":5,"once":true}]}],
        \\ "SessionStart":[{"hooks":[{"type":"prompt","prompt":"summarize","model":"claude-haiku-4-5"}]}]
        \\}}
    ;
    var p = try parse(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.defs.len);

    const pre = p.defs[0];
    try testing.expectEqual(hook_event.Event.pre_tool_use, pre.event);
    try testing.expectEqualStrings("Bash(git *)", pre.matcher);
    try testing.expectEqual(HookType.command, pre.hook_type);
    try testing.expectEqualStrings("./pre.sh", pre.body);
    try testing.expectEqual(@as(?u32, 5), pre.timeout_s);
    try testing.expect(pre.once);

    const ss = p.defs[1];
    try testing.expectEqual(hook_event.Event.session_start, ss.event);
    try testing.expectEqualStrings("*", ss.matcher); // default matcher
    try testing.expectEqual(HookType.prompt, ss.hook_type);
    try testing.expectEqualStrings("summarize", ss.body);
    try testing.expectEqualStrings("claude-haiku-4-5", ss.model);
}

test "parse tolerates missing hooks and bad json" {
    var a = try parse(testing.allocator, "");
    defer a.deinit();
    try testing.expectEqual(@as(usize, 0), a.defs.len);

    var b = try parse(testing.allocator, "{\"other\":1}");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 0), b.defs.len);

    var c = try parse(testing.allocator, "not json");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.defs.len);
}

test "parse skips unknown event names" {
    const json =
        \\{"hooks":{"NotAReal":[{"hooks":[{"type":"command","command":"x"}]}]}}
    ;
    var p = try parse(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.defs.len);
}

test "parse reads if, shell, statusMessage, async, asyncRewake, model, headers, allowedEnvVars" {
    const json =
        \\{"hooks":{
        \\ "PreToolUse":[{"matcher":"Bash(*)","hooks":[{"type":"command","command":"./c.sh","if":"Bash(git *)","shell":"bash","statusMessage":"linting","async":true,"asyncRewake":true}]}],
        \\ "UserPromptSubmit":[{"hooks":[{"type":"prompt","prompt":"check","model":"claude-haiku-4-5"}]}],
        \\ "PostToolUse":[{"hooks":[{"type":"http","url":"https://api.example.com/h","headers":{"X-Auth":"$TOKEN","X-Fixed":"v"},"allowedEnvVars":["TOKEN"]}]}]
        \\}}
    ;
    var p = try parse(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.defs.len);

    // Hooks iterate in object-insertion order; locate by event to stay robust.
    var cmd: ?HookDef = null;
    var prm: ?HookDef = null;
    var htp: ?HookDef = null;
    for (p.defs) |d| {
        switch (d.hook_type) {
            .command => cmd = d,
            .prompt => prm = d,
            .http => htp = d,
            else => {},
        }
    }

    const c = cmd.?;
    try testing.expectEqual(hook_event.Event.pre_tool_use, c.event);
    try testing.expectEqualStrings("Bash(git *)", c.if_cond);
    try testing.expectEqualStrings("bash", c.shell);
    try testing.expectEqualStrings("linting", c.status_message);
    try testing.expect(c.is_async);
    try testing.expect(c.async_rewake);

    const pr = prm.?;
    try testing.expectEqual(hook_event.Event.user_prompt_submit, pr.event);
    try testing.expectEqualStrings("check", pr.body);
    try testing.expectEqualStrings("claude-haiku-4-5", pr.model);

    const ht = htp.?;
    try testing.expectEqual(hook_event.Event.post_tool_use, ht.event);
    try testing.expectEqualStrings("https://api.example.com/h", ht.body);
    // headers re-serialized into an owned JSON object slice that parses back.
    try testing.expect(ht.headers_json.len > 0);
    var hp = try std.json.parseFromSlice(std.json.Value, testing.allocator, ht.headers_json, .{});
    defer hp.deinit();
    try testing.expect(hp.value == .object);
    try testing.expectEqualStrings("$TOKEN", hp.value.object.get("X-Auth").?.string);
    try testing.expectEqualStrings("v", hp.value.object.get("X-Fixed").?.string);
    // allowedEnvVars captured as a single-element slice.
    try testing.expectEqual(@as(usize, 1), ht.allowed_env_vars.len);
    try testing.expectEqualStrings("TOKEN", ht.allowed_env_vars[0]);
}

test "parse defaults new fields and implies async from asyncRewake" {
    const json =
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"./s.sh","asyncRewake":true}]}]}}
    ;
    var p = try parse(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.defs.len);
    const d = p.defs[0];
    // unset string fields default to "".
    try testing.expectEqualStrings("", d.if_cond);
    try testing.expectEqualStrings("", d.shell);
    try testing.expectEqualStrings("", d.status_message);
    try testing.expectEqualStrings("", d.headers_json);
    try testing.expectEqual(@as(usize, 0), d.allowed_env_vars.len);
    // asyncRewake true with no explicit async still yields is_async true.
    try testing.expect(d.async_rewake);
    try testing.expect(d.is_async);
}
