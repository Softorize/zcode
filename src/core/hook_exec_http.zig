//! Task 7 (PRD #534, hooks-15 + part of hooks-02): execute `http` hook types by
//! POSTing the per-event JSON stdin payload to a configured URL, gated by:
//!
//!   1. A URL allowlist (`allowedHttpHookUrls`): undefined -> no restriction;
//!      `[]` -> block all; non-empty -> the URL must match a `*`-glob pattern
//!      (execHttpHook.ts:138-145, urlMatchesPattern execHttpHook.ts:64).
//!   2. An SSRF guard refusing private / link-local / CGNAT / cloud-metadata
//!      destinations (loopback allowed) (ssrfGuard.ts:42/216). We reuse
//!      `ssrf_guard.zig` and the central `egress.zig` policy.
//!   3. Allowlisted env-var interpolation into headers: only names listed in the
//!      hook's `allowedEnvVars` are interpolated for `$VAR` / `${VAR}`; every
//!      other reference becomes empty, and CR / LF / NUL are stripped from the
//!      final value (interpolateEnvVars execHttpHook.ts:89, sanitizeHeaderValue
//!      execHttpHook.ts:76).
//!
//! The actual POST routes through `providers/common.callHttpWithPolicy`, which
//! already refuses plaintext http:// to non-loopback hosts and applies the
//! egress policy. 2xx -> success (body parsed via `hook_io.parseOutput` for the
//! stdout contract); a transport error or non-2xx status -> non-blocking error
//! (the agent continues, matching the reference's non-blocking outcome).
//!
//! SessionStart / Setup http hooks are skipped by the dispatch layer
//! (utils/hooks.ts:1850-1859 deadlock guard); this module does not re-check the
//! event, it just executes what it is given.

const std = @import("std");
const hook_config = @import("hook_config.zig");
const hook_io = @import("hook_io.zig");
const ssrf_guard = @import("ssrf_guard.zig");
const egress = @import("egress.zig");
const permission_rules = @import("permission_rules.zig");
const env = @import("env.zig");
const providers_common = @import("../providers/common.zig");

/// Default http hook timeout (ms). The reference uses 10 minutes
/// (execHttpHook.ts:12/147). Task 8 owns full timeout enforcement; this is the
/// default that task applies, kept here so the http path documents its contract.
pub const HTTP_TIMEOUT_MS: u64 = 600_000;

/// Outcome of running an http hook. Mirrors `hook_exec_prompt.PromptOutcome`:
/// `blocked` means the response's stdout contract blocked the event; a transport
/// error or non-2xx status is a non-blocking error (`ran == true`,
/// `blocked == false`, `error_message` set). All owned slices are duped onto the
/// supplied allocator and freed in `deinit`.
pub const HttpOutcome = struct {
    ran: bool = false,
    blocked: bool = false,
    /// Blocking reason surfaced from the response (decision/permission deny). Owned.
    reason: ?[]u8 = null,
    /// `additionalContext` injected by the response, if any. Owned.
    additional_context: ?[]u8 = null,
    /// Non-blocking error description (SSRF refusal, allowlist miss, transport
    /// error, non-2xx). Owned.
    error_message: ?[]u8 = null,

    pub fn deinit(self: *HttpOutcome, allocator: std.mem.Allocator) void {
        if (self.reason) |v| allocator.free(v);
        if (self.additional_context) |v| allocator.free(v);
        if (self.error_message) |v| allocator.free(v);
        self.reason = null;
        self.additional_context = null;
        self.error_message = null;
    }

    fn nonBlockingError(allocator: std.mem.Allocator, msg: []const u8) HttpOutcome {
        return .{
            .ran = true,
            .blocked = false,
            .error_message = allocator.dupe(u8, msg) catch null,
        };
    }
};

/// How a configured `allowedHttpHookUrls` setting gates a URL. `none` means the
/// setting was undefined (no restriction); `empty` means it was present but `[]`
/// (block every http hook); `patterns` carries the glob entries to match.
pub const UrlAllowlist = union(enum) {
    none,
    empty,
    patterns: []const []const u8,
};

/// Match a single `*`-glob URL pattern against a URL. The reference escapes the
/// pattern as a regex with `*` -> `.*` and anchors it (execHttpHook.ts:64); our
/// `permission_rules.globMatch` already implements `*` (any run) + `?` (one
/// char) anchored full-match, so reuse it instead of a second glob.
pub fn urlMatchesPattern(url: []const u8, pattern: []const u8) bool {
    // A bare "*" matches everything (the common "allow all" entry).
    if (std.mem.eql(u8, pattern, "*")) return true;
    return permission_rules.globMatch(pattern, url);
}

/// Decide whether `url` is permitted by the allowlist. `none` -> always allowed;
/// `empty` -> never allowed; `patterns` -> allowed iff one pattern matches.
pub fn urlAllowed(url: []const u8, allowlist: UrlAllowlist) bool {
    return switch (allowlist) {
        .none => true,
        .empty => false,
        .patterns => |pats| {
            for (pats) |p| {
                if (urlMatchesPattern(url, p)) return true;
            }
            return false;
        },
    };
}

/// True when `name` is in the hook's `allowedEnvVars` list (exact match).
fn envVarAllowed(name: []const u8, allowed: []const []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// Strip CR, LF, and NUL from a header value to defeat header-injection via an
/// interpolated env var (sanitizeHeaderValue execHttpHook.ts:76). The result is
/// written into `out` (a caller-owned ArrayList).
fn appendSanitized(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        if (c == '\r' or c == '\n' or c == 0) continue;
        try out.append(allocator, c);
    }
}

/// Interpolate `$VAR` and `${VAR}` references in a header value. A reference is
/// resolved to its environment value ONLY when the variable name is in
/// `allowed_env_vars`; any other reference (not allowlisted, or undefined)
/// resolves to the empty string. The resulting value has CR / LF / NUL stripped.
/// Caller owns the returned slice.
pub fn interpolateEnvVars(
    allocator: std.mem.Allocator,
    value: []const u8,
    allowed_env_vars: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '$') {
            try out.append(allocator, value[i]);
            i += 1;
            continue;
        }
        // A trailing bare '$' is a literal '$'.
        if (i + 1 >= value.len) {
            try out.append(allocator, '$');
            i += 1;
            continue;
        }

        var name_start: usize = i + 1;
        var name_end: usize = name_start;
        var braced = false;
        if (value[name_start] == '{') {
            braced = true;
            name_start += 1;
            name_end = name_start;
            while (name_end < value.len and value[name_end] != '}') name_end += 1;
        } else {
            while (name_end < value.len and isEnvNameChar(value[name_end])) name_end += 1;
        }

        const name = value[name_start..name_end];
        // An empty name (a literal "$" followed by a non-name char, or "${}") is
        // emitted verbatim so it round-trips rather than vanishing.
        if (name.len == 0) {
            try out.append(allocator, '$');
            if (braced) try out.append(allocator, '{');
            i = name_start;
            continue;
        }

        // Resolve only allowlisted names; everything else becomes empty.
        if (envVarAllowed(name, allowed_env_vars)) {
            if (env.getenv(name)) |val| try out.appendSlice(allocator, val);
        }

        // Advance past the consumed reference (including the closing brace).
        i = name_end;
        if (braced and name_end < value.len and value[name_end] == '}') i += 1;
    }

    // Strip control chars from the assembled value in a single final pass.
    const raw = try out.toOwnedSlice(allocator);
    defer allocator.free(raw);
    var sanitized: std.ArrayList(u8) = .empty;
    errdefer sanitized.deinit(allocator);
    try appendSanitized(&sanitized, allocator, raw);
    return sanitized.toOwnedSlice(allocator);
}

fn isEnvNameChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Run the SSRF check for `url`: refuse when the host is an IP literal in (or a
/// hostname resolving into) a blocked range. Loopback is allowed. Returns an
/// error message (non-blocking) when blocked, null when the URL may proceed.
fn ssrfCheck(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    if (ssrf_guard.urlIsBlocked(allocator, url)) {
        return "http hook URL refused by SSRF guard (private/link-local/metadata range)";
    }
    return null;
}

/// Build the list of headers for the curl call: always `Content-Type:
/// application/json`, plus each header from `def.headers_json` with its value
/// env-interpolated and sanitized. Caller owns the returned slice and each entry
/// (free via `freeHeaders`).
fn buildHeaders(
    allocator: std.mem.Allocator,
    def: hook_config.HookDef,
) ![][]u8 {
    var headers: std.ArrayList([]u8) = .empty;
    errdefer freeHeadersList(&headers, allocator);

    try headers.append(allocator, try allocator.dupe(u8, "Content-Type: application/json"));

    if (def.headers_json.len == 0) return headers.toOwnedSlice(allocator);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, def.headers_json, .{}) catch
        return headers.toOwnedSlice(allocator);
    defer parsed.deinit();
    if (parsed.value != .object) return headers.toOwnedSlice(allocator);

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const raw_val = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => continue, // non-string header values are skipped
        };
        const val = try interpolateEnvVars(allocator, raw_val, def.allowed_env_vars);
        defer allocator.free(val);
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ key, val });
        try headers.append(allocator, line);
    }

    return headers.toOwnedSlice(allocator);
}

fn freeHeadersList(headers: *std.ArrayList([]u8), allocator: std.mem.Allocator) void {
    for (headers.items) |h| allocator.free(h);
    headers.deinit(allocator);
}

fn freeHeaders(headers: [][]u8, allocator: std.mem.Allocator) void {
    for (headers) |h| allocator.free(h);
    allocator.free(headers);
}

/// Execute an http hook. `json_input` is the per-event stdin payload (Task 4);
/// `allowlist` is the resolved `allowedHttpHookUrls` setting. This is the
/// fully-unit-testable core: the allowlist/SSRF/interpolation gates run before
/// any network call, and the POST goes through `callHttpWithPolicy`.
pub fn runHttpHook(
    allocator: std.mem.Allocator,
    def: hook_config.HookDef,
    json_input: []const u8,
    allowlist: UrlAllowlist,
) !HttpOutcome {
    const url = def.body;
    if (url.len == 0) {
        return HttpOutcome.nonBlockingError(allocator, "http hook has no url");
    }

    // 1. URL allowlist gate.
    if (!urlAllowed(url, allowlist)) {
        return HttpOutcome.nonBlockingError(allocator, "http hook URL not in allowedHttpHookUrls");
    }

    // 2. SSRF guard (loopback allowed; private/link-local/metadata refused).
    if (ssrfCheck(allocator, url)) |msg| {
        return HttpOutcome.nonBlockingError(allocator, msg);
    }

    // 3. Build interpolated + sanitized headers.
    const headers = buildHeaders(allocator, def) catch
        return HttpOutcome.nonBlockingError(allocator, "http hook header build failed");
    defer freeHeaders(headers, allocator);

    // Widen the parameter type from [][]u8 to []const []const u8 for the call.
    var header_views: std.ArrayList([]const u8) = .empty;
    defer header_views.deinit(allocator);
    for (headers) |h| header_views.append(allocator, h) catch {};

    // 4. POST the payload. callHttpWithPolicy enforces the central egress policy
    //    again (plaintext-to-non-local refusal, allow/deny lists) and maps a
    //    non-2xx status to an error, which we treat as non-blocking.
    //    Task 8 (hooks-08): `def.timeout_s` (the parsed `timeout`, in seconds)
    //    overrides the 10-minute http default; curl's own --max-time enforces it.
    const effective_ms: u64 = if (def.timeout_s) |s| @as(u64, s) * 1000 else HTTP_TIMEOUT_MS;
    const timeout_ms: u32 = @intCast(@min(effective_ms, @as(u64, std.math.maxInt(u32))));
    const body = providers_common.callHttpWithPolicy(
        allocator,
        .POST,
        url,
        header_views.items,
        json_input,
        timeout_ms,
        .{},
    ) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "http hook request failed: {s}", .{@errorName(err)}) catch
            return HttpOutcome.nonBlockingError(allocator, "http hook request failed");
        defer allocator.free(msg);
        return HttpOutcome.nonBlockingError(allocator, msg);
    };
    defer allocator.free(body);

    // 5. Parse the 2xx response body through the standard stdout contract.
    var parsed = hook_io.parseOutput(allocator, body);
    defer parsed.deinit();

    const decision_block = if (parsed.output.decision) |d| std.ascii.eqlIgnoreCase(d, "block") else false;
    const blocked = decision_block or parsed.output.permission_decision == .deny;

    var outcome: HttpOutcome = .{ .ran = true, .blocked = blocked };
    if (blocked) {
        const reason = parsed.output.permission_decision_reason orelse parsed.output.stop_reason orelse parsed.output.reason orelse "http hook blocked";
        outcome.reason = allocator.dupe(u8, reason) catch null;
    }
    if (parsed.output.additional_context) |ac| {
        outcome.additional_context = allocator.dupe(u8, ac) catch null;
    }
    return outcome;
}

/// Read the `allowedHttpHookUrls` setting across all disk sources. The dispatch
/// layer calls this once per http hook and passes the result to `runHttpHook`.
/// Undefined across every source -> `.none` (no restriction). Present but `[]`
/// (or only non-string entries) -> `.empty` (block all). Non-empty -> `.patterns`
/// (owned slice; caller frees both the outer slice and each entry, or uses
/// `freeAllowlist`). The reference reads this from the same merged settings.
const settings_sources = @import("settings_sources.zig");

pub fn readAllowlist(allocator: std.mem.Allocator, cwd: []const u8) UrlAllowlist {
    var seen_key = false;
    var pats: std.ArrayList([]const u8) = .empty;
    errdefer freeAllowlistList(&pats, allocator);

    for (settings_sources.sourceOrder()) |source| {
        var parsed = (settings_sources.readSource(allocator, cwd, source, null) catch null) orelse continue;
        defer parsed.deinit();
        const arr = settings_sources.getArray(parsed.value, "allowedHttpHookUrls") orelse continue;
        // The key is present in at least one source. Later sources override:
        // reset the accumulated patterns so the highest-precedence source wins.
        seen_key = true;
        freeAllowlistList(&pats, allocator);
        pats = .empty;
        for (arr) |item| {
            switch (item) {
                .string => |s| pats.append(allocator, allocator.dupe(u8, s) catch continue) catch {},
                else => {},
            }
        }
    }

    if (!seen_key) {
        freeAllowlistList(&pats, allocator);
        return .none;
    }
    if (pats.items.len == 0) {
        freeAllowlistList(&pats, allocator);
        return .empty;
    }
    return .{ .patterns = pats.toOwnedSlice(allocator) catch &.{} };
}

fn freeAllowlistList(pats: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (pats.items) |p| allocator.free(p);
    pats.deinit(allocator);
}

/// Free an allowlist returned by `readAllowlist`. A `.none` / `.empty` value
/// owns nothing; `.patterns` owns the outer slice and each entry.
pub fn freeAllowlist(allowlist: UrlAllowlist, allocator: std.mem.Allocator) void {
    switch (allowlist) {
        .none, .empty => {},
        .patterns => |pats| {
            for (pats) |p| allocator.free(p);
            allocator.free(pats);
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "urlMatchesPattern: exact and wildcard suffixes" {
    try testing.expect(urlMatchesPattern("https://api.example.com/x", "https://api.example.com/*"));
    try testing.expect(urlMatchesPattern("https://api.example.com/v1/hooks", "https://api.example.com/*"));
    try testing.expect(!urlMatchesPattern("https://evil.example.com/x", "https://api.example.com/*"));
    // A bare "*" matches everything.
    try testing.expect(urlMatchesPattern("https://anything/here", "*"));
    // Exact match (no wildcard).
    try testing.expect(urlMatchesPattern("https://x.test/h", "https://x.test/h"));
    try testing.expect(!urlMatchesPattern("https://x.test/h2", "https://x.test/h"));
}

test "urlAllowed: none allows all, empty blocks all, patterns gate" {
    try testing.expect(urlAllowed("https://anything/", .none));
    try testing.expect(!urlAllowed("https://anything/", .empty));

    const pats = [_][]const u8{"https://api.example.com/*"};
    try testing.expect(urlAllowed("https://api.example.com/h", .{ .patterns = &pats }));
    try testing.expect(!urlAllowed("https://other.test/h", .{ .patterns = &pats }));
}

test "interpolateEnvVars: resolves allowlisted, blanks others, strips CRLF" {
    const alloc = testing.allocator;
    // Set a process env var for the duration of the test. setenv is available
    // via libc; the test runner installs rt before tests, so getenv works.
    _ = setenv("ZCODE_TEST_TOKEN", "secret123", 1);
    defer _ = unsetenv("ZCODE_TEST_TOKEN");

    const allowed = [_][]const u8{"ZCODE_TEST_TOKEN"};

    // Allowlisted -> resolved.
    const a = try interpolateEnvVars(alloc, "Bearer $ZCODE_TEST_TOKEN", &allowed);
    defer alloc.free(a);
    try testing.expectEqualStrings("Bearer secret123", a);

    // Braced form also resolves.
    const b = try interpolateEnvVars(alloc, "v=${ZCODE_TEST_TOKEN};", &allowed);
    defer alloc.free(b);
    try testing.expectEqualStrings("v=secret123;", b);

    // Non-allowlisted -> blanked.
    const c = try interpolateEnvVars(alloc, "x=$HOME", &allowed);
    defer alloc.free(c);
    try testing.expectEqualStrings("x=", c);
}

test "interpolateEnvVars: strips a CRLF-injected value to a single line" {
    const alloc = testing.allocator;
    // A C env var cannot carry an embedded NUL (setenv truncates at it), so the
    // injection vector that matters in practice is CR/LF. The NUL-strip path is
    // exercised directly below via appendSanitized.
    _ = setenv("ZCODE_TEST_CRLF", "good\r\nX-Evil: injected\rtrail", 1);
    defer _ = unsetenv("ZCODE_TEST_CRLF");

    const allowed = [_][]const u8{"ZCODE_TEST_CRLF"};
    const v = try interpolateEnvVars(alloc, "$ZCODE_TEST_CRLF", &allowed);
    defer alloc.free(v);
    // CR and LF are removed; the value collapses to one line.
    try testing.expect(std.mem.indexOfScalar(u8, v, '\r') == null);
    try testing.expect(std.mem.indexOfScalar(u8, v, '\n') == null);
    try testing.expectEqualStrings("goodX-Evil: injectedtrail", v);
}

test "appendSanitized: strips CR, LF, and NUL bytes" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendSanitized(&out, alloc, "a\rb\nc\x00d");
    try testing.expectEqualStrings("abcd", out.items);
}

test "runHttpHook: empty allowlist blocks before any network" {
    const alloc = testing.allocator;
    const def = hook_config.HookDef{
        .event = .post_tool_use,
        .hook_type = .http,
        .body = "https://api.example.com/h",
    };
    var outcome = try runHttpHook(alloc, def, "{}", .empty);
    defer outcome.deinit(alloc);
    try testing.expect(outcome.ran);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
}

test "runHttpHook: allowlist miss is a non-blocking error" {
    const alloc = testing.allocator;
    const pats = [_][]const u8{"https://allowed.test/*"};
    const def = hook_config.HookDef{
        .event = .post_tool_use,
        .hook_type = .http,
        .body = "https://other.test/h",
    };
    var outcome = try runHttpHook(alloc, def, "{}", .{ .patterns = &pats });
    defer outcome.deinit(alloc);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
}

test "runHttpHook: SSRF metadata host is refused before any POST" {
    const alloc = testing.allocator;
    const def = hook_config.HookDef{
        .event = .post_tool_use,
        .hook_type = .http,
        // 169.254.169.254 is AWS IMDS; the SSRF guard must refuse it. Allowlist
        // is .none so the only gate that can stop it is the SSRF check.
        .body = "http://169.254.169.254/latest/meta-data/",
    };
    var outcome = try runHttpHook(alloc, def, "{}", .none);
    defer outcome.deinit(alloc);
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.error_message != null);
    // The refusal message names the SSRF guard, proving we stopped at step 2.
    try testing.expect(std.mem.indexOf(u8, outcome.error_message.?, "SSRF") != null);
}

test "ssrfCheck: loopback is allowed past the SSRF gate" {
    const alloc = testing.allocator;
    // 127.0.0.1 must pass the SSRF check (returns null = allowed).
    try testing.expect(ssrfCheck(alloc, "http://127.0.0.1:8080/health") == null);
    // 169.254.169.254 must be refused (returns a message).
    try testing.expect(ssrfCheck(alloc, "http://169.254.169.254/x") != null);
}

test "buildHeaders: always includes Content-Type and interpolates allowlisted headers" {
    const alloc = testing.allocator;
    _ = setenv("ZCODE_TEST_AUTH", "tok-9", 1);
    defer _ = unsetenv("ZCODE_TEST_AUTH");

    const allowed = [_][]const u8{"ZCODE_TEST_AUTH"};
    const def = hook_config.HookDef{
        .event = .post_tool_use,
        .hook_type = .http,
        .body = "https://api.example.com/h",
        .headers_json =
        \\{"X-Auth":"Bearer $ZCODE_TEST_AUTH","X-Fixed":"v","X-Secret":"$NOT_ALLOWED"}
        ,
        .allowed_env_vars = &allowed,
    };
    const headers = try buildHeaders(alloc, def);
    defer freeHeaders(headers, alloc);

    var saw_ct = false;
    var saw_auth = false;
    var saw_fixed = false;
    var saw_secret = false;
    for (headers) |h| {
        if (std.mem.eql(u8, h, "Content-Type: application/json")) saw_ct = true;
        if (std.mem.eql(u8, h, "X-Auth: Bearer tok-9")) saw_auth = true;
        if (std.mem.eql(u8, h, "X-Fixed: v")) saw_fixed = true;
        // Non-allowlisted ref blanked.
        if (std.mem.eql(u8, h, "X-Secret: ")) saw_secret = true;
    }
    try testing.expect(saw_ct);
    try testing.expect(saw_auth);
    try testing.expect(saw_fixed);
    try testing.expect(saw_secret);
}
