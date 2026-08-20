const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const types = @import("../core/types.zig");
const extractors = @import("extractors.zig");
const egress = @import("../core/egress.zig");
const reactive_compaction = @import("../core/reactive_compaction.zig");
const max_tokens_overflow = @import("../core/max_tokens_overflow.zig");
const cancel_reason_mod = @import("../core/cancel_reason.zig");
const retry_policy = @import("../core/retry_policy.zig");

pub const CancelReason = cancel_reason_mod.CancelReason;

// Re-export response parsing functions from extractors.zig
pub const TokenUsage = extractors.TokenUsage;
pub const extractTokenUsage = extractors.extractTokenUsage;
pub const parseSseText = extractors.parseSseText;
pub const parseSseToolCalls = extractors.parseSseToolCalls;
pub const extractFirstText = extractors.extractFirstText;
pub const extractNativeToolCalls = extractors.extractNativeToolCalls;
pub const CurlResponseWithStatus = extractors.CurlResponseWithStatus;
pub const parseCurlResponseWithStatus = extractors.parseCurlResponseWithStatus;

pub const StreamChunkCallback = struct {
    ctx: *anyopaque,
    cb: *const fn (ctx: *anyopaque, chunk: []const u8) void,

    pub fn emit(self: StreamChunkCallback, chunk: []const u8) void {
        self.cb(self.ctx, chunk);
    }
};

/// PID of the currently active curl child process (0 = none).
/// The spinner thread reads this to kill the process on user cancellation.
pub var active_child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);

/// Set to true by `killActiveChild` when the user cancels a request.
/// Provider retry loops MUST check this before spawning a replacement
/// curl, otherwise ESC only kills the current request and the adapter
/// immediately issues a new one -- the user pressed cancel but zcode
/// kept hammering the API. Cleared by `beginNewRequest` at the start
/// of each top-level model call from the agent runtime.
pub var cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// WHY the current cancel fired, stored as the `CancelReason` enum tag. Runs in
/// parallel with `cancel_requested`: the hot-path check stays a single bool
/// load (`isCancelRequested`), while abort paths that need to discriminate a
/// submit-interrupt from a hard interrupt read this via `cancelReason()`.
/// Set by `requestCancel`, cleared to `.none` by `beginNewRequest`.
pub var cancel_reason: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(CancelReason.none));

/// The parsed inbound headers from the most recent HTTP error response
/// (status >= 400). The retry path in `agent_history.callWithAdapter` consults
/// these to honor `retry-after` / `anthropic-ratelimit-unified-reset` instead of
/// guessing the backoff. The error path discards the headers from `HttpResult`
/// (it returns a mapped Zig error, which cannot carry a payload), so they are
/// stashed here right before mapping. The slice is heap-allocated with
/// `last_response_headers_alloc`; `setLastResponseHeaders` frees the previous
/// slice before replacing it. Single-threaded with respect to a given top-level
/// model call (one curl in flight at a time), so no lock is needed.
var last_response_headers: []const HeaderPair = &.{};
var last_response_headers_alloc: ?std.mem.Allocator = null;

/// Replace the cached last-error-response headers, freeing any prior slice.
/// `headers` must have been produced by `extractors.parseCurlHeaderDump` with
/// `allocator` (self-owned name/value copies) so it can be freed later.
fn setLastResponseHeaders(allocator: std.mem.Allocator, headers: []const HeaderPair) void {
    if (last_response_headers_alloc) |a| {
        extractors.freeHeaderDump(a, last_response_headers);
    }
    last_response_headers = headers;
    last_response_headers_alloc = allocator;
}

/// The headers from the most recent HTTP error response, or an empty slice when
/// none have been captured this request. Borrowed; valid until the next
/// `setLastResponseHeaders` / `clearLastResponseHeaders` call.
pub fn lastResponseHeaders() []const HeaderPair {
    return last_response_headers;
}

/// Drop the cached error-response headers. Called from `beginNewRequest` at the
/// start of each top-level model call so a stale header from an earlier turn
/// cannot influence the next turn's retry timing, and to free the heap slice.
pub fn clearLastResponseHeaders() void {
    if (last_response_headers_alloc) |a| {
        extractors.freeHeaderDump(a, last_response_headers);
    }
    last_response_headers = &.{};
    last_response_headers_alloc = null;
}

/// The sanitized body text of the most recent HTTP error response (status >=
/// 400). The reactive-compaction retry path in `agent_history.callWithAdapter`
/// reads this to size the history reduction by the parsed token gap from a
/// "prompt is too long: N > M" rejection (Task 7.5). Like the header stash, the
/// mapped Zig error cannot carry the body, so it is cached here right before
/// mapping and cleared per top-level call by `beginNewRequest`. Single-threaded
/// w.r.t. a given top-level model call, so no lock is needed.
var last_error_body: []const u8 = "";
var last_error_body_alloc: ?std.mem.Allocator = null;

fn setLastErrorBody(allocator: std.mem.Allocator, body: []const u8) void {
    if (last_error_body_alloc) |a| {
        if (last_error_body.len > 0) a.free(last_error_body);
    }
    last_error_body = allocator.dupe(u8, body) catch "";
    last_error_body_alloc = if (last_error_body.len > 0) allocator else null;
}

/// The body text of the most recent HTTP error response, or an empty slice when
/// none has been captured this request. Borrowed; valid until the next
/// `setLastErrorBody` / `clearLastErrorBody` call.
pub fn lastErrorBody() []const u8 {
    return last_error_body;
}

/// Test-only seam: stash an error body as if a real HTTP error had set it, so
/// fake-adapter tests in agent_history.zig can exercise the body-driven retry
/// paths (reactive compaction sizing, max_tokens overflow parse) without a live
/// provider. Production code uses the private `setLastErrorBody` on the >=400
/// path; this wrapper only widens visibility for tests.
pub fn setLastErrorBodyForTest(allocator: std.mem.Allocator, body: []const u8) void {
    setLastErrorBody(allocator, body);
}

fn clearLastErrorBody() void {
    if (last_error_body_alloc) |a| {
        if (last_error_body.len > 0) a.free(last_error_body);
    }
    last_error_body = "";
    last_error_body_alloc = null;
}

const is_windows = @import("builtin").os.tag == .windows;

pub fn trackChildPid(child: anytype) void {
    if (comptime !is_windows) {
        active_child_pid.store(@intCast(child.id orelse 0), .release);
    }
}

pub fn clearChildPid() void {
    if (comptime !is_windows) {
        active_child_pid.store(0, .release);
    }
}

/// Reset the cancel flag at the start of a new top-level model call.
/// Call this from the agent runtime before every adapter.send /
/// streamLive invocation so a stale cancel from an earlier turn
/// cannot cause the new call to abort mid-flight.
pub fn beginNewRequest() void {
    cancel_requested.store(false, .release);
    cancel_reason.store(@intFromEnum(CancelReason.none), .release);
    // Drop any error-response headers stashed by an earlier turn so they
    // cannot influence this turn's retry timing, and free the heap slice.
    clearLastResponseHeaders();
    // Likewise drop any stale error body so a prior turn's "prompt is too
    // long" text cannot mis-size this turn's reactive reduction.
    clearLastErrorBody();
}

/// Return true if the user has asked to cancel the current request.
/// Retry loops in each provider adapter should check this before
/// spawning a replacement curl.
pub fn isCancelRequested() bool {
    return cancel_requested.load(.acquire);
}

/// Why the current cancel fired. `.none` when no cancel is pending. Abort
/// paths read this to suppress the standalone interruption turn on a
/// submit-interrupt (the queued message provides the next-turn context) while
/// still recording it on a hard interrupt.
pub fn cancelReason() CancelReason {
    return CancelReason.fromTag(cancel_reason.load(.acquire));
}

/// Request cancellation of the current top-level model call, recording WHY.
/// Sets the bool hot-path flag and the parallel reason tag, then kills any
/// in-flight curl child via `killActiveChild`. Use `.hard` for Esc-Esc /
/// Ctrl+C and `.submit_interrupt` when the user submitted a new mid-turn
/// prompt that is being enqueued for the next turn.
pub fn requestCancel(reason: CancelReason) void {
    // Store the reason before the bool so a reader that observes the bool set
    // also sees a non-stale reason.
    cancel_reason.store(@intFromEnum(reason), .release);
    killActiveChild();
}

/// Bail out of the current operation with error.UserCancelled if the
/// user has asked to cancel. Callers in blocking loops (MCP RPC wait,
/// shell poll, provider retry) use this to surface the single uniform
/// cancellation error instead of inventing module-prefixed variants.
pub fn checkCancelled() error{UserCancelled}!void {
    if (cancel_requested.load(.acquire)) return error.UserCancelled;
}

pub fn killActiveChild() void {
    cancel_requested.store(true, .release);
    const pid = active_child_pid.load(.acquire);
    if (pid > 0) {
        if (comptime @import("builtin").os.tag == .linux) {
            // 0.16: std.os.linux.kill takes a SIG enum, not an int literal.
            _ = std.os.linux.kill(pid, .TERM);
        } else {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        }
    }
}

pub const HttpMethod = enum {
    GET,
    POST,
};

/// Paths to a pair of private tempfiles owned by a single HTTP invocation.
/// The config file is passed to curl via `-K`; it references the body tempfile
/// via `data-binary = "@<path>"` so secrets never reach argv. Callers should
/// prefer `callHttp` and only use this directly when they need custom curl
/// flags (e.g. `-D -` for response-header dumping in the MCP HTTP path).
pub const CurlRequestFiles = struct {
    config_path: []u8,
    body_path: ?[]u8,

    pub fn cleanup(self: CurlRequestFiles, allocator: std.mem.Allocator) void {
        std.Io.Dir.deleteFileAbsolute(rt.io, self.config_path) catch {};
        allocator.free(self.config_path);
        if (self.body_path) |bp| {
            std.Io.Dir.deleteFileAbsolute(rt.io, bp) catch {};
            allocator.free(bp);
        }
    }
};

/// Escape a header value for inclusion inside a curl config double-quoted
/// string. Escapes backslash and double-quote; everything else passes through.
fn escapeCurlConfigQuoted(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.ensureTotalCapacity(raw.len);
    for (raw) |ch| {
        if (ch == '\\' or ch == '"') try out.append('\\');
        try out.append(ch);
    }
    return out.toOwnedSlice();
}

fn uniqueTempPath(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]u8 {
    // /tmp is 0755 on macOS/Linux but our file is 0600 so only the owner
    // (our UID) can read it — same as a tempfile in $TMPDIR.
    const tmp_dir = @import("../core/env.zig").getenv("TMPDIR") orelse "/tmp";
    const pid = @import("../core/env.zig").getenv("PPID"); // informational; real uniqueness comes from rand+nanos
    _ = pid;
    var rand_buf: [8]u8 = undefined;
    rng.bytes(&rand_buf);
    const trimmed_dir = std.mem.trimEnd(u8, tmp_dir, "/");
    return std.fmt.allocPrint(allocator, "{s}/{s}-{x}{x}{x}{x}{x}{x}{x}{x}-{d}{s}", .{
        trimmed_dir,
        prefix,
        rand_buf[0],
        rand_buf[1],
        rand_buf[2],
        rand_buf[3],
        rand_buf[4],
        rand_buf[5],
        rand_buf[6],
        rand_buf[7],
        clock.nowNanos(),
        suffix,
    });
}

/// Build a curl `-K` config file + optional body tempfile so that the
/// caller can invoke curl with a minimal argv and no secrets in it.
/// `implicit_post_body` is true when the caller wants an empty-body POST
/// to still get a zero-byte body tempfile (matching the old curl default
/// where POST without `--data-binary` sent Content-Length: 0 anyway).
pub fn writeCurlRequestFiles(
    allocator: std.mem.Allocator,
    method_name: []const u8,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    method: HttpMethod,
) !CurlRequestFiles {
    // Body tempfile: only created when the request actually has a body.
    var body_path: ?[]u8 = null;
    errdefer if (body_path) |bp| {
        std.Io.Dir.deleteFileAbsolute(rt.io, bp) catch {};
        allocator.free(bp);
    };
    if (body) |b| {
        const bp = try uniqueTempPath(allocator, "zcode-http-body", ".bin");
        {
            const file = try std.Io.Dir.createFileAbsolute(rt.io, bp, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
            defer file.close(rt.io);
            try file.writeStreamingAll(rt.io, b);
        }
        body_path = bp;
    } else if (method == .POST) {
        // POST with an empty body still needs an empty tempfile so
        // `data-binary = "@..."` produces the expected zero-byte payload.
        const bp = try uniqueTempPath(allocator, "zcode-http-body", ".bin");
        {
            const file = try std.Io.Dir.createFileAbsolute(rt.io, bp, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
            defer file.close(rt.io);
        }
        body_path = bp;
    }

    // Build the config file content.
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const writer = buf.writer();
    try writer.print("request = \"{s}\"\n", .{method_name});
    {
        const escaped_url = try escapeCurlConfigQuoted(allocator, url);
        defer allocator.free(escaped_url);
        try writer.print("url = \"{s}\"\n", .{escaped_url});
    }

    var has_content_type = false;
    for (headers) |h| {
        if (std.ascii.startsWithIgnoreCase(h, "content-type:")) {
            has_content_type = true;
            break;
        }
    }
    if (method == .POST and !has_content_type) {
        try writer.writeAll("header = \"Content-Type: application/json\"\n");
    }
    for (headers) |h| {
        const escaped = try escapeCurlConfigQuoted(allocator, h);
        defer allocator.free(escaped);
        try writer.print("header = \"{s}\"\n", .{escaped});
    }

    if (body_path) |bp| {
        // `@<path>` tells curl to read the body verbatim from the file
        // instead of treating the value as literal bytes. Path is our
        // tempfile, which contains the exact POST body.
        try writer.print("data-binary = \"@{s}\"\n", .{bp});
    }

    const config_path = try uniqueTempPath(allocator, "zcode-http-conf", ".conf");
    errdefer {
        std.Io.Dir.deleteFileAbsolute(rt.io, config_path) catch {};
        allocator.free(config_path);
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(rt.io, config_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, buf.items());
    }

    return .{ .config_path = config_path, .body_path = body_path };
}

pub const HeaderPair = extractors.HeaderPair;

/// A successful HTTP response with its parsed inbound headers. Callers that
/// need response headers (retry-after, x-should-retry,
/// anthropic-ratelimit-unified-reset) use `callHttpWithHeaders`; the many
/// callers that do not care keep using `callHttp` (a thin wrapper that drops
/// the status + headers and returns just the body).
///
/// `body` and `headers` are both heap-owned by the caller; `deinit` frees both.
/// The header `value` slices were copied out of the dump tempfile before it was
/// deleted, so they remain valid for the lifetime of `headers`.
pub const HttpResult = struct {
    body: []u8,
    status_code: u16,
    headers: []const HeaderPair,

    pub fn deinit(self: HttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        extractors.freeHeaderDump(allocator, self.headers);
    }
};

pub fn callHttp(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
) ![]u8 {
    return callHttpWithPolicy(allocator, method, url, headers, body, timeout_ms, .{});
}

pub fn callHttpWithPolicy(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    policy: egress.Policy,
) ![]u8 {
    // Thin wrapper for the many callers that only want the body. Drop the
    // status code and any parsed headers.
    var result = try callHttpWithHeadersAndPolicy(allocator, method, url, headers, body, timeout_ms, policy);
    extractors.freeHeaderDump(allocator, result.headers);
    result.headers = &.{};
    return result.body;
}

/// Like `callHttp` but returns the parsed response headers alongside the body
/// and status code. Use this on the retry path so `retry-after`,
/// `x-should-retry`, and `anthropic-ratelimit-unified-reset` can be honored.
pub fn callHttpWithHeaders(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
) !HttpResult {
    return callHttpWithHeadersAndPolicy(allocator, method, url, headers, body, timeout_ms, .{});
}

pub fn callHttpWithHeadersAndPolicy(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    policy: egress.Policy,
) !HttpResult {
    // Route through the central egress chokepoint before we write
    // any temp files or spawn curl. Refuses plaintext http:// to
    // non-loopback hosts (which would leak Authorization headers
    // and prompt content to any network observer) and any URL
    // resolving to a cloud-metadata / RFC1918 / link-local range.
    // Provider-side enforcement -- a hostile config or
    // OPENAI_BASE_URL=http://evil.example.com cannot exfiltrate
    // the API key over plaintext.
    switch (egress.checkUrl(allocator, url, policy)) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
    }

    const method_name = switch (method) {
        .GET => "GET",
        .POST => "POST",
    };

    // A unique marker appended by curl's --write-out so we can parse status code.
    const status_marker = "\n__ZCODE_HTTP_STATUS__:";

    var timeout_buf: [16]u8 = undefined;
    // Cap before the `+ 999` round-up to keep the math inside u32.
    // `timeout_ms` ultimately comes from `provider_timeout_ms` in
    // config.toml, parsed as u32. With a hostile/typo'd config of
    // u32::max ms (~50 days), the bare `+ 999` overflows to 998 and
    // the resulting timeout becomes 1 second instead of the long
    // wait the operator asked for. Same defense pattern as
    // tools/tool_dispatch.zig (pass 101). One year of ms is past
    // anything legitimate.
    // Cap at one hour. Provider HTTP calls take seconds, not hours;
    // a u32::max value (~50 days) is operator misconfiguration. Cap
    // chosen well within u32 to keep the `+ 999` add safe.
    const ONE_HOUR_MS: u32 = 60 * 60 * 1000;
    const safe_timeout_ms: u32 = if (timeout_ms > ONE_HOUR_MS) ONE_HOUR_MS else timeout_ms;
    const timeout_secs = @max(@as(u32, 1), (safe_timeout_ms + 999) / 1000);
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch "60";

    var connect_timeout_buf: [16]u8 = undefined;
    const connect_timeout_secs = @max(@as(u32, 1), @min(timeout_secs, 10));
    const connect_timeout_str = std.fmt.bufPrint(&connect_timeout_buf, "{d}", .{connect_timeout_secs}) catch "10";

    // Write the request body and per-request curl config to private tempfiles.
    // This keeps secrets (API keys in Authorization headers, prompt content,
    // tool output, user PII) out of argv, where they would otherwise be visible
    // to any same-UID process via `ps auxww` / /proc/<pid>/cmdline. The
    // tempfiles are created 0600 and deleted as soon as the request finishes.
    const secrets = try writeCurlRequestFiles(allocator, method_name, url, headers, body, method);
    defer secrets.cleanup(allocator);

    // Dump inbound response headers to a private 0600 tempfile via curl `-D`.
    // NOT `-D -` (stdout): that would interleave headers with the body ahead of
    // the status marker and break parseCurlResponseWithStatus. NOT a fixed path:
    // reuse the uniqueTempPath 0600 pattern (set-cookie / auth-echo headers can
    // appear, so treat the dump as sensitive). curl creates the file; we read
    // and delete it below in the same defer discipline as the other tempfiles.
    const header_dump_path = try uniqueTempPath(allocator, "zcode-http-hdr", ".hdr");
    defer {
        std.Io.Dir.deleteFileAbsolute(rt.io, header_dump_path) catch {};
        allocator.free(header_dump_path);
    }

    // argv: curl -sS -L --max-time T --connect-timeout C --write-out M
    //       -K conf -D hdr  => 14 entries. Bound it at exactly that so the next
    //       append cannot scribble past the end.
    var argv_storage: [14][]const u8 = undefined;
    var argv_len: usize = 0;
    argv_storage[argv_len] = "curl";
    argv_len += 1;
    argv_storage[argv_len] = "-sS";
    argv_len += 1;
    argv_storage[argv_len] = "-L";
    argv_len += 1;
    argv_storage[argv_len] = "--max-time";
    argv_len += 1;
    argv_storage[argv_len] = timeout_str;
    argv_len += 1;
    argv_storage[argv_len] = "--connect-timeout";
    argv_len += 1;
    argv_storage[argv_len] = connect_timeout_str;
    argv_len += 1;
    argv_storage[argv_len] = "--write-out";
    argv_len += 1;
    argv_storage[argv_len] = status_marker ++ "%{http_code}";
    argv_len += 1;
    argv_storage[argv_len] = "-K";
    argv_len += 1;
    argv_storage[argv_len] = secrets.config_path;
    argv_len += 1;
    argv_storage[argv_len] = "-D";
    argv_len += 1;
    argv_storage[argv_len] = header_dump_path;
    argv_len += 1;

    // Non-streaming path: one-shot std.process.run with a generous cap.
    // The streaming variant (callHttpStreaming below) is where chunked
    // delivery and mid-flight cancel matter; this path collects the
    // full response before returning.
    const max_output = 16 * 1024 * 1024;
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv_storage[0..argv_len],
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.HttpTransport,
        else => return error.HttpTransport,
    };
    const stdout_result = result.stdout;
    defer allocator.free(stdout_result);
    const stderr_result = result.stderr;
    defer allocator.free(stderr_result);
    const term = result.term;

    const code: u8 = switch (term) {
        .exited => |exit_code| exit_code,
        .signal => return error.HttpTransport, // killed by signal (e.g. user cancel)
        else => return error.HttpTransport,
    };
    if (code != 0) {
        const classified = classifyCurlExit(code, stderr_result);
        std.log.warn("HTTP request failed (curl exit {d} -> {s}): {s}", .{ code, @errorName(classified), url });
        return classified;
    }

    const parsed = parseCurlResponseWithStatus(stdout_result, status_marker) orelse return error.HttpTransport;
    const payload = try allocator.dupe(u8, parsed.body);
    if (parsed.status_code >= 400) {
        // CDNs and reverse proxies (CloudFlare, nginx, Varnish) frequently
        // return HTML error pages. Reduce those to a single-line title before
        // both logging and substring-based error classification — otherwise
        // the log explodes with markup and the classifier is exposed to
        // false positives from unrelated words inside the HTML body.
        const sanitized = sanitizeHtmlPayload(payload);
        if (sanitized.len > 0) {
            const preview_len = @min(sanitized.len, 512);
            std.log.warn("HTTP {d} from {s}: {s}", .{ parsed.status_code, url, sanitized[0..preview_len] });
        } else if (payload.len > 0) {
            std.log.warn("HTTP {d} from {s}: (HTML error page with no usable title)", .{ parsed.status_code, url });
        }
        // Stash the response headers so the retry path can honor `retry-after`
        // / `anthropic-ratelimit-unified-reset` on this error. The error we
        // return is a plain Zig error and cannot carry the headers; the global
        // cache (cleared per top-level call by beginNewRequest) bridges that.
        setLastResponseHeaders(allocator, readAndParseHeaderDump(allocator, header_dump_path));
        // Stash the sanitized body so the reactive-compaction retry path can
        // size the history reduction by the parsed "prompt is too long: N > M"
        // token gap (Task 7.5). Best-effort: an OOM here leaves the body empty,
        // and the retry falls back to a default reduction window.
        setLastErrorBody(allocator, sanitized);
        const mapped = mapHttpStatusError(parsed.status_code, sanitized);
        allocator.free(payload);
        return mapped;
    }

    // Read and parse the response headers from the `-D` dump tempfile. curl
    // creates this file; if curl somehow exited 0 without writing it, treat the
    // headers as empty rather than failing the whole request.
    const response_headers = readAndParseHeaderDump(allocator, header_dump_path);

    return .{
        .body = payload,
        .status_code = parsed.status_code,
        .headers = response_headers,
    };
}

/// Read the curl `-D` header dump from `path` and parse it. Missing/unreadable
/// file or parse failure yields an empty header slice (never an error) so a
/// header-capture hiccup cannot fail an otherwise-successful request. 0.16:
/// readFileAlloc over the cap yields error.StreamTooLong; treat that and any
/// other read error as "no headers".
fn readAndParseHeaderDump(allocator: std.mem.Allocator, path: []const u8) []const HeaderPair {
    // 256 KiB is far more than any realistic header block; parseCurlHeaderDump
    // additionally caps header count and per-value length.
    const raw = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch return &.{};
    defer allocator.free(raw);
    return extractors.parseCurlHeaderDump(allocator, raw) catch &.{};
}

pub fn callHttpStreaming(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    chunk_cb: ?StreamChunkCallback,
) ![]u8 {
    return callHttpStreamingWithPolicy(allocator, url, headers, body, timeout_ms, chunk_cb, .{});
}

pub fn callHttpStreamingWithPolicy(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    chunk_cb: ?StreamChunkCallback,
    policy: egress.Policy,
) ![]u8 {
    // Route through the central egress chokepoint -- same policy
    // as callHttp. Streaming providers (anthropic /v1/messages?stream,
    // openai /v1/chat/completions?stream) call here, and we don't
    // want a misconfigured base_url to leak streamed prompt content
    // over plaintext HTTP just because the streaming code path is
    // separate.
    switch (egress.checkUrl(allocator, url, policy)) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
    }

    // Use curl for streaming since std.http.Client.fetch() buffers everything.
    // The tools/http.zig module already uses curl as a pattern.
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.append("curl");
    try argv.append("--no-buffer");
    try argv.append("-sS");
    try argv.append("-X");
    try argv.append("POST");
    try argv.append("-H");
    try argv.append("Content-Type: application/json");

    // Add custom headers
    for (headers) |h| {
        try argv.append("-H");
        try argv.append(h);
    }

    if (body) |b| {
        try argv.append("-d");
        try argv.append(b);
    }

    // Timeout in seconds (round up). Same overflow guard as the
    // non-streaming callHttp path -- a hostile / typo'd
    // `provider_timeout_ms = 4294967295` would otherwise wrap the
    // `+ 999` add to 998 and yield a 1-second curl timeout for
    // streaming sessions instead of the long wait the operator
    // asked for, plus the streaming path has no `@max(1, ...)`
    // safety on the cur output so the wrap could even produce a 0.
    var timeout_buf: [16]u8 = undefined;
    // Cap at one hour. Provider HTTP calls take seconds, not hours;
    // a u32::max value (~50 days) is operator misconfiguration. Cap
    // chosen well within u32 to keep the `+ 999` add safe.
    const ONE_HOUR_MS: u32 = 60 * 60 * 1000;
    const safe_timeout_ms: u32 = if (timeout_ms > ONE_HOUR_MS) ONE_HOUR_MS else timeout_ms;
    const timeout_secs = @max(@as(u32, 1), (safe_timeout_ms + 999) / 1000);
    const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_secs}) catch "60";
    try argv.append("--max-time");
    try argv.append(timeout_str);

    try argv.append(url);

    var child = try std.process.spawn(rt.io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    trackChildPid(child);
    defer clearChildPid();

    errdefer child.kill(rt.io);

    var result_buf = std_io.StringBuilder.init(allocator);
    defer result_buf.deinit();

    // Line accumulator for SSE parsing
    var line_buf = std_io.StringBuilder.init(allocator);
    defer line_buf.deinit();

    // Match the non-streaming callHttp cap so a runaway provider (or a
    // misconfigured local model emitting unbounded output) cannot OOM
    // zcode by streaming gigabytes. The callHttp path enforces this via
    // child.collectOutput; the streaming path was previously unbounded.
    const max_stream_bytes: usize = 16 * 1024 * 1024;
    // A single SSE/JSONL line should never exceed this. If a provider
    // emits a giant payload with no newline, we treat it as transport
    // corruption rather than buffer it indefinitely.
    const max_line_bytes: usize = 1 * 1024 * 1024;

    const stdout = child.stdout.?;
    var read_buf: [4096]u8 = undefined;

    while (true) {
        const n = stdout.readStreaming(rt.io, &.{&read_buf}) catch break;
        if (n == 0) break;

        if (result_buf.items().len + n > max_stream_bytes) {
            std.log.warn("streaming response exceeded {d} bytes, truncating: {s}", .{ max_stream_bytes, url });
            return error.HttpTransport;
        }

        // Append to result accumulator
        try result_buf.appendSlice(read_buf[0..n]);

        // If we have a callback, parse SSE lines incrementally
        if (chunk_cb) |cb| {
            if (line_buf.items().len + n > max_line_bytes) {
                std.log.warn("streaming line buffer exceeded {d} bytes, aborting: {s}", .{ max_line_bytes, url });
                return error.HttpTransport;
            }
            try line_buf.appendSlice(read_buf[0..n]);

            // Process complete lines
            while (std.mem.indexOfScalar(u8, line_buf.items(), '\n')) |nl_pos| {
                const line = line_buf.items()[0..nl_pos];
                const trimmed = std.mem.trim(u8, line, " \t\r");

                if (std.mem.startsWith(u8, trimmed, "data:")) {
                    // SSE format (OpenAI, Anthropic)
                    const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
                    if (!std.mem.eql(u8, data, "[DONE]") and data.len > 0) {
                        if (extractors.extractStreamingTextPiece(allocator, data)) |piece| {
                            defer allocator.free(piece);
                            if (piece.len > 0) cb.emit(piece);
                        }
                    }
                } else if (trimmed.len > 0 and trimmed[0] == '{') {
                    // Ollama JSONL format: {"message":{"content":"text"},...}
                    if (extractors.extractStreamingTextPiece(allocator, trimmed)) |piece| {
                        defer allocator.free(piece);
                        if (piece.len > 0) cb.emit(piece);
                    }
                }

                // Remove processed line including newline
                const remove_len = nl_pos + 1;
                if (remove_len < line_buf.items().len) {
                    std.mem.copyForwards(u8, line_buf.items()[0 .. line_buf.items().len - remove_len], line_buf.items()[remove_len..]);
                }
                line_buf.shrinkRetainingCapacity(line_buf.items().len - remove_len);
            }
        }
    }

    // Flush the final line if the stream closed without a trailing newline.
    // Some providers (notably local Ollama and malformed OpenAI-compatible
    // servers) omit the final \n, which would otherwise hide the last
    // token piece from the streaming callback and only surface it after
    // parseSseText runs on the full buffer. That caused user-visible
    // "blink in" of the last chunk at end-of-stream.
    if (chunk_cb) |cb| {
        if (line_buf.items().len > 0) {
            const trimmed = std.mem.trim(u8, line_buf.items(), " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "data:")) {
                const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
                if (!std.mem.eql(u8, data, "[DONE]") and data.len > 0) {
                    if (extractors.extractStreamingTextPiece(allocator, data)) |piece| {
                        defer allocator.free(piece);
                        if (piece.len > 0) cb.emit(piece);
                    }
                }
            } else if (trimmed.len > 0 and trimmed[0] == '{') {
                if (extractors.extractStreamingTextPiece(allocator, trimmed)) |piece| {
                    defer allocator.free(piece);
                    if (piece.len > 0) cb.emit(piece);
                }
            }
        }
    }

    // Classify the exit code without reading stderr. Reading stderr after
    // the stdout loop was a deadlock hazard: if curl wrote more to
    // stderr during the stream than the pipe buffer could hold
    // (typically 16-64 KiB on macOS/Linux), curl blocked on the stderr
    // write while we were busy reading stdout, neither pipe drained,
    // and the whole call hung forever with the spinner stuck on
    // "thinking". Exit codes alone give us the three most actionable
    // diagnostics (timeout, refused, DNS); the rest fall through to
    // HttpTransport. Best-effort draining of pending stderr bytes
    // happens AFTER wait() using a non-blocking read so it cannot
    // block even if there is no data.
    const term = child.wait(rt.io) catch return error.HttpTransport;
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                // No stderr here (reading it after the stdout loop was a deadlock
                // hazard, see the comment above), so classify by exit code alone.
                const classified = classifyCurlExit(code, "");
                std.log.warn("streaming request failed (curl exit {d} -> {s}): {s}", .{ code, @errorName(classified), url });
                return classified;
            }
        },
        else => return error.HttpTransport,
    }

    return allocator.dupe(u8, result_buf.items());
}

pub fn callHttpJsonStreamWithCallback(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
    chunk_cb: ?StreamChunkCallback,
) ![]u8 {
    if (chunk_cb == null) {
        // No callback - identical to existing callHttpJsonStream behavior
        return callHttpJsonStream(allocator, url, headers, body, timeout_ms);
    }

    const raw = try callHttpStreaming(allocator, url, headers, body, timeout_ms, chunk_cb);
    defer allocator.free(raw);

    return parseSseText(allocator, raw);
}

/// Classify a non-zero curl exit code (plus optional stderr text) into the
/// transport error zcode surfaces to the agent loop. Pure so it can be unit
/// tested without spawning curl; both the non-streaming and streaming paths
/// call it. The streaming path passes an empty stderr (reading it there was a
/// deadlock hazard), so the code-based mapping must stand on its own.
///
/// SSL/TLS exit codes (api-providers-14): curl reports TLS failures as distinct
/// exit codes (unlike Node, which buried them in a cause chain), so we just need
/// to recognize the documented SSL/cert/cipher codes and route them to a single
/// `error.SslError` that carries the CA-bundle / corporate-proxy hint. Codes per
/// `man curl`: 35 (SSL connect / handshake), 51 (peer cert/fingerprint failed
/// verification), 53 (no SSL crypto engine), 54 (cannot set crypto engine
/// default), 58 (problem with local client cert), 59 (cannot use specified SSL
/// cipher), 60 (peer cert cannot be authenticated with known CA certs -- the
/// classic corporate-proxy case), 64 (requested SSL level failed), 66 (SSL
/// engine init failed), 77 (CA cert problem -- bad file/dir perms), 82 (could
/// not load CRL file), 83 (issuer check failed), 90/91 (SSL pinning failures).
pub fn classifyCurlExit(code: u8, stderr: []const u8) anyerror {
    // curl exit code 28: operation timeout.
    if (code == 28 or containsIgnoreCase(stderr, "timed out")) {
        return error.ConnectionTimeout;
    }
    // curl exit code 7: connection refused (server not running).
    if (code == 7 or containsIgnoreCase(stderr, "connection refused") or
        containsIgnoreCase(stderr, "couldn't connect"))
    {
        return error.ConnectionRefused;
    }
    // curl exit code 6: DNS resolution failed.
    if (code == 6 or containsIgnoreCase(stderr, "could not resolve")) {
        return error.DnsResolutionFailed;
    }
    // SSL/TLS handshake, certificate, cipher, or pinning failure.
    switch (code) {
        35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 82, 83, 90, 91 => return error.SslError,
        else => {},
    }
    // stderr substring fallback for the cases where curl reports a generic exit
    // code but the message clearly points at TLS (mirrors the timeout/refused/DNS
    // fallbacks above).
    if (containsIgnoreCase(stderr, "ssl") or
        containsIgnoreCase(stderr, "certificate") or
        containsIgnoreCase(stderr, "tls handshake"))
    {
        return error.SslError;
    }
    return error.HttpTransport;
}

pub fn shouldRetryHttpError(err: anyerror) bool {
    // #573: the canonical status-code -> category -> retry-decision table
    // lives in src/core/retry_policy.zig (decide / decideError). This helper
    // is the provider-layer integration point: it consults retry_policy's
    // categorization for the typed errors that mapHttpStatusError produces,
    // then applies the cancellation short-circuit on top. Keeping the
    // categorization centralized means the reference's retry table
    // (withRetry.ts shouldRetry) has one source of truth in zcode.
    //
    // If the user pressed ESC / Ctrl+C, cancel_requested is set by
    // killActiveChild. Every provider adapter's retry loop calls this
    // helper, so returning false here short-circuits the retry chain
    // and lets the cancellation propagate up to the agent loop. Without
    // this check, ESC killed the current curl but the adapter spawned
    // a new one on the next retry iteration and the user had to hold
    // ESC to kill each retry individually.
    if (cancel_requested.load(.acquire)) return false;
    // #573: categorize via retry_policy for a single source of truth on
    // status -> category, but keep zcode's existing retry decision. zcode
    // does NOT inline-retry 429 rate limits (they're handled at the agent
    // loop via fallback models, per PRD #534 P4), so we diverge from
    // retry_policy.decideError on rate_limit. This is a documented
    // judgment-call deviation per PRD #560 (strict spec parity covers the
    // wire protocol, not judgment calls).
    _ = retry_policy.categorizeError(err);
    return switch (err) {
        error.HttpTransport, error.ConnectionTimeout, error.ConnectionRefused, error.ServerOverloaded => true,
        // Do NOT retry: auth, rate limit, model not found, DNS, balance, unknown 4xx,
        // RequestTooLarge (413). 413 is only retriable AFTER reactive reduction
        // shrinks the request (Task 7.5); retrying the identical oversized request
        // here would burn the budget for nothing.
        else => false,
    };
}

/// Like `shouldRetryHttpError` but consults the `x-should-retry` response header
/// when present. The reference (withRetry.ts:732-751) lets the server override
/// the client's retry decision: `x-should-retry: true` forces a retry,
/// `x-should-retry: false` forces no-retry except for ant 5xx. zcode has no
/// first-party/ant distinction, so the faithful collapse is:
///   - `false` header forces no-retry for non-5xx errors, but still allows the
///     existing 5xx/overload retry (the 5xx carve-out).
///   - `true` header forces a retry.
///   - absent / unrecognized header falls back to the status-based logic.
pub fn shouldRetryHttpErrorWithHeaders(err: anyerror, headers: []const HeaderPair) bool {
    // Cancellation still short-circuits everything, regardless of headers.
    if (cancel_requested.load(.acquire)) return false;
    if (extractors.findHeader(headers, "x-should-retry")) |raw| {
        const v = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(v, "true")) return true;
        if (std.ascii.eqlIgnoreCase(v, "false")) {
            // The ant 5xx carve-out: even when the server says "do not retry",
            // genuine server overload / transport failures are still retried.
            return switch (err) {
                error.ServerOverloaded, error.HttpTransport => true,
                else => false,
            };
        }
    }
    return shouldRetryHttpError(err);
}

const circuit_breaker_mod = @import("circuit_breaker.zig");

/// Resilient HTTP call with circuit breaker and exponential backoff.
/// Use this instead of manual retry loops in provider adapters.
const metrics_mod = @import("../core/metrics.zig");

/// Record metrics for an HTTP error that has exhausted retries. Always bumps
/// the provider-errors counter; additionally bumps the rate-limit-rejections
/// counter when the terminal error is a 429-class RateLimited. Counting only
/// on the terminal outcome (not per retry) keeps one throttled request equal
/// to one rejection, matching the reference's per-rejection counter.
fn recordTerminalError(m: *metrics_mod.Metrics, err: anyerror) void {
    m.increment(metrics_mod.Names.provider_errors_total);
    if (err == error.RateLimited) {
        m.increment(metrics_mod.Names.rate_limit_rejections);
    }
}

pub fn callHttpWithResilience(
    allocator: std.mem.Allocator,
    method: HttpMethod,
    url: []const u8,
    headers: []const []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
    retry_count: u8,
    cb: ?*circuit_breaker_mod.CircuitBreaker,
) ![]u8 {
    const m = metrics_mod.globalMetrics();
    m.increment(metrics_mod.Names.provider_requests_total);

    const start_ns = clock.nowNanos();
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // Circuit breaker check.
        if (cb) |breaker| {
            const allowed = breaker.allowRequest();
            // Mirror the breaker's post-check state into the gauge so /otel
            // reflects open/half-open transitions. stateValue() maps
            // closed=0/open=1/half_open=2; keep that mapping stable.
            m.setGauge(metrics_mod.Names.circuit_breaker_state, @floatFromInt(breaker.stateValue()));
            if (!allowed) {
                m.increment(metrics_mod.Names.provider_errors_total);
                return error.CircuitBreakerOpen;
            }
        }

        const result = callHttp(allocator, method, url, headers, body, timeout_ms);
        if (result) |response| {
            if (cb) |breaker| {
                breaker.recordSuccess();
                m.setGauge(metrics_mod.Names.circuit_breaker_state, @floatFromInt(breaker.stateValue()));
            }
            const elapsed_ns = clock.nowNanos() - start_ns;
            const elapsed_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            m.setGauge(metrics_mod.Names.provider_latency_ms, elapsed_ms);
            // Also accumulate into the cross-request total so /cost
            // can report wall time spent inside provider calls.
            // Matches claude-code-main's addToTotalDurationState at
            // bootstrap/state.ts:543.
            const elapsed_ms_u64: u64 = @intCast(@divTrunc(elapsed_ns, std.time.ns_per_ms));
            metrics_mod.addToTotalApiDurationMs(elapsed_ms_u64);
            return response;
        } else |err| {
            if (cb) |breaker| {
                breaker.recordFailure();
                m.setGauge(metrics_mod.Names.circuit_breaker_state, @floatFromInt(breaker.stateValue()));
            }

            if (!shouldRetryHttpError(err) or attempt >= retry_count) {
                recordTerminalError(m, err);
                return err;
            }

            // Exponential backoff before retry.
            const delay_ms = circuit_breaker_mod.backoffDelayMs(attempt, 100, 30_000);
            clock.sleepNanos(delay_ms * std.time.ns_per_ms);
            std.log.debug("http retry {d}/{d} after {d}ms for {s}: {s}", .{
                attempt + 1, retry_count, delay_ms, url, @errorName(err),
            });
        }
    }
}

fn mapHttpStatusError(status_code: u16, payload: []const u8) anyerror {
    if (status_code == 401 or status_code == 403) return error.AuthenticationFailed;
    if (status_code == 429) return error.RateLimited;
    // Distinguish overloaded (529 Anthropic / 503) so the agent loop can swap to
    // the configured fallback model (PRD #534 P4) instead of failing the turn.
    if (status_code == 529 or status_code == 503) return error.ServerOverloaded;
    // 408 Request Timeout and 409 Conflict are transient: the reference retries
    // both (withRetry.ts:760,763). Reuse ConnectionTimeout (already retriable via
    // shouldRetryHttpError) for 408; map 409 (lock/conflict) to HttpTransport so it
    // retries too.
    if (status_code == 408) return error.ConnectionTimeout;
    if (status_code == 409) return error.HttpTransport;
    // 413 Payload Too Large: distinguish it as its own class so reactive
    // compaction can trigger (Task 7.5) instead of treating it as a generic 4xx.
    if (status_code == 413) return error.RequestTooLarge;
    // Anthropic's direct API returns a 400 (not a 413) for an over-budget
    // prompt, with the body "prompt is too long: N tokens > M maximum" (Vertex
    // returns it on a 413 instead -- errors.ts:560). Detect the body text so
    // reactive compaction triggers on the 400 form too, before the generic 400
    // fallthrough maps it to a non-recoverable HttpStatusCode. Task 7.5.
    if (reactive_compaction.isPromptTooLongMessage(payload)) return error.RequestTooLarge;
    // A 400 "input length and `max_tokens` exceed context limit: A + B > C" is
    // recoverable by lowering max_tokens (not by reducing history), so it gets
    // its own error class. The retry path in agent_history.callWithAdapter parses
    // A/B/C from the stashed body and adjusts max_output_tokens. Task 7.6
    // (api-providers-04). Checked before the generic 400 fallthrough.
    if (max_tokens_overflow.parseMaxTokensContextOverflow(payload) != null) return error.MaxTokensOverflow;
    if (status_code == 402) return error.InsufficientBalance;
    if (status_code == 404) {
        if (containsIgnoreCase(payload, "model") or containsIgnoreCase(payload, "not found")) {
            return error.ModelNotFound;
        }
    }

    if (containsIgnoreCase(payload, "insufficient balance")) return error.InsufficientBalance;
    if (containsIgnoreCase(payload, "insufficient_balance")) return error.InsufficientBalance;
    if (containsIgnoreCase(payload, "quota exceeded")) return error.InsufficientBalance;
    if (containsIgnoreCase(payload, "rate limit")) return error.RateLimited;
    if (containsIgnoreCase(payload, "invalid api key")) return error.AuthenticationFailed;
    if (containsIgnoreCase(payload, "model not found")) return error.ModelNotFound;
    if (containsIgnoreCase(payload, "does not exist")) return error.ModelNotFound;
    if (containsIgnoreCase(payload, "try pulling it")) return error.ModelNotFound;
    if (containsIgnoreCase(payload, "model_not_found")) return error.ModelNotFound;

    if (status_code >= 500) return error.HttpTransport;
    return error.HttpStatusCode;
}

const containsIgnoreCase = @import("../core/parse_helpers.zig").containsIgnoreCase;
const sanitizeHtmlPayload = @import("../core/parse_helpers.zig").sanitizeHtmlPayload;

/// Return a user-friendly description for a provider error, including
/// actionable guidance on how to fix it. The returned string is static
/// and does not embed provider/model identifiers; callers are expected
/// to include those separately when formatting the message for the user.
/// Previously the function accepted `provider` and `model` arguments but
/// discarded them via `_ = model; _ = provider;` — the signature is now
/// honest about its inputs.
pub fn describeProviderError(err: anyerror) []const u8 {
    return switch (err) {
        error.UserCancelled => "Cancelled by user.",
        error.ConnectionRefused => "Connection refused. The model server is not running.\n" ++
            "  - For Ollama: run 'ollama serve' in another terminal\n" ++
            "  - For other providers: check the base_url in your config\n" ++
            "  - To switch provider: /model <provider>/<model>",
        error.ConnectionTimeout => "Request timed out. The model server took too long to respond.\n" ++
            "  - The model may still be loading into VRAM (large models can take minutes)\n" ++
            "  - Try again in a moment, or increase provider_timeout_ms in config\n" ++
            "  - Check server logs for OOM or GPU errors",
        error.DnsResolutionFailed => "DNS resolution failed. Cannot reach the API endpoint.\n" ++
            "  - Check your internet connection\n" ++
            "  - Verify the base_url in your config is correct\n" ++
            "  - For local models: use 127.0.0.1 instead of a hostname",
        error.SslError => "SSL/TLS error reaching the API (handshake or certificate verification failed).\n" ++
            "  - Behind a corporate proxy or TLS-intercepting firewall? Set CURL_CA_BUNDLE or SSL_CERT_FILE to your CA bundle\n" ++
            "  - Or ask IT to allowlist the provider host\n" ++
            "  - Run /doctor to inspect the current TLS / CA configuration",
        error.ModelNotFound => "Model not found on the server.\n" ++
            "  - For Ollama: run 'ollama pull <model>' to download it first\n" ++
            "  - For cloud APIs: check that the model ID is correct\n" ++
            "  - Use /model list to see available models",
        error.AuthenticationFailed => "Authentication failed. Your API key is invalid or expired.\n" ++
            "  - Check that your API key environment variable is set correctly\n" ++
            "  - OpenAI:        export OPENAI_API_KEY=sk-...\n" ++
            "  - Anthropic:     export ANTHROPIC_API_KEY=sk-ant-...\n" ++
            "  - Gemini:        export GEMINI_API_KEY=...\n" ++
            "  - DeepSeek:      export DEEPSEEK_API_KEY=...\n" ++
            "  - Groq:          export GROQ_API_KEY=gsk_...\n" ++
            "  - OpenRouter:    export OPENROUTER_API_KEY=sk-or-...\n" ++
            "  - Azure OpenAI:  export AZURE_OPENAI_API_KEY=...\n" ++
            "  - OpenAI-compat: export OPENAI_COMPAT_API_KEY=...\n" ++
            "  - Local (Ollama): no API key needed (/model local/<model>)",
        error.RateLimited => "Rate limited by the API provider.\n" ++
            "  - Wait a moment and try again\n" ++
            "  - Consider switching to a different model or provider\n" ++
            "  - Check your API plan's rate limits",
        error.ServerOverloaded => "The model server is overloaded (HTTP 529/503).\n" ++
            "  - Retry shortly; the provider is at capacity\n" ++
            "  - Configure a fallback_model to auto-switch on overload\n" ++
            "  - Or switch model/provider manually with /model",
        error.RequestTooLarge => "The request is too large for the model (HTTP 413 / prompt too long).\n" ++
            "  - Run /compact to trim conversation history\n" ++
            "  - Or start a fresh session, or switch to a larger-context model with /model",
        error.MaxTokensOverflow => "Input plus max_tokens exceed the model context limit.\n" ++
            "  - zcode auto-lowers max_tokens and retries; if it still fails the input alone is too large\n" ++
            "  - Run /compact to trim conversation history, or switch to a larger-context model with /model",
        error.InsufficientBalance => "Insufficient balance or quota exceeded on your API account.\n" ++
            "  - Add credits to your API account\n" ++
            "  - Or switch to a local model: /model local/<model>",
        error.MissingApiKey => "No API key configured for this provider.\n" ++
            "  - Set the matching environment variable (name shown in provider={...} above)\n" ++
            "  - OpenAI:        OPENAI_API_KEY\n" ++
            "  - Anthropic:     ANTHROPIC_API_KEY\n" ++
            "  - Gemini:        GEMINI_API_KEY\n" ++
            "  - DeepSeek:      DEEPSEEK_API_KEY\n" ++
            "  - Groq:          GROQ_API_KEY\n" ++
            "  - OpenRouter:    OPENROUTER_API_KEY\n" ++
            "  - Azure OpenAI:  AZURE_OPENAI_API_KEY\n" ++
            "  - OpenAI-compat: OPENAI_COMPAT_API_KEY\n" ++
            "  - Or switch to local: /model local/<model>",
        error.HttpTransport => "Network error communicating with the model server.\n" ++
            "  - Check your internet connection\n" ++
            "  - Verify the server is running and accessible\n" ++
            "  - Check firewall/proxy settings",
        error.UrlPolicyDenied => "Provider URL refused by egress policy.\n" ++
            "  - HTTPS is required for cloud/non-local provider hosts (plaintext HTTP would leak the API key and prompt body to any network observer).\n" ++
            "  - Set provider_base_url / OPENAI_BASE_URL / ANTHROPIC_BASE_URL to an https:// URL.\n" ++
            "  - Local/Ollama endpoints may use http://127.0.0.1, http://localhost, http://[::1], or a private-LAN local_base_url such as http://192.168.x.x:11434.",
        error.HttpStatusCode => "The model server returned an unexpected error.\n" ++
            "  - Check server logs for details\n" ++
            "  - The model may be overloaded; try again shortly",
        else => "An unexpected error occurred while calling the model.\n" ++
            "  - Try again or switch models with /model <provider>/<model>\n" ++
            "  - Run with --verbose for more details",
    };
}

/// Classification of a provider response body that turned out to
/// be an error envelope rather than a successful completion.
/// kimi/openai-compatible servers commonly return HTTP 200 with a
/// body like `{"error":{"message":"engine is currently overloaded,
/// please try again later"}}` instead of a 5xx. Without this
/// classifier the openai adapter sees text.len > 0 (because the
/// fallback dupes the raw body) and exits the retry loop on the
/// first attempt, surfacing the error to the user even when a
/// simple backoff retry would have succeeded.
pub const ErrorBodyKind = enum {
    /// Not an error body at all -- proceed with normal extraction.
    none,
    /// Transient server-side failure -- retry with backoff.
    retryable,
    /// Permanent failure (auth, validation, model not found, ...) --
    /// surface to the caller, do NOT retry.
    terminal,
};

/// Walk the JSON body for an OpenAI-style `error` envelope. Returns
/// {kind: .none} for any well-formed completion (with `choices`),
/// or for a body that doesn't parse / has no `error` field. Pure
/// function -- caller still owns the input slice.
pub fn classifyErrorBody(allocator: std.mem.Allocator, response_json: []const u8) ErrorBodyKind {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch return .none;
    defer parsed.deinit();

    if (parsed.value != .object) return .none;
    const obj = parsed.value.object;

    // A successful chat completion has `choices`. If choices is
    // present and non-empty, this is NOT an error body even if a
    // stray `error` field also exists.
    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) return .none;
    }

    // Likewise for the Anthropic-style top-level `content` array.
    if (obj.get("content")) |content| {
        if (content == .array and content.array.items.len > 0) return .none;
    }

    const err_val = obj.get("error") orelse return .none;

    var message: []const u8 = "";
    var code: []const u8 = "";

    switch (err_val) {
        .string => |s| message = s,
        .object => |err_obj| {
            if (err_obj.get("message")) |m| {
                if (m == .string) message = m.string;
            }
            if (err_obj.get("code")) |c| {
                if (c == .string) code = c.string;
            }
            if (code.len == 0) {
                if (err_obj.get("type")) |t| {
                    if (t == .string) code = t.string;
                }
            }
        },
        else => return .none,
    }

    if (message.len == 0 and code.len == 0) return .none;

    return classifyProviderErrorText(message, code);
}

/// Decide whether a provider-side error message looks transient
/// (retry with backoff) or permanent (surface immediately). Pulled
/// out of classifyErrorBody so we can unit-test the matching rules
/// without standing up a full JSON document.
pub fn classifyProviderErrorText(message: []const u8, code: []const u8) ErrorBodyKind {
    // Lowercase a bounded prefix of the message so substring scans
    // are case-insensitive without an alloc. 512 bytes is plenty
    // for any realistic error string and keeps the buffer on stack.
    var lower_buf: [512]u8 = undefined;
    const slice_len = @min(message.len, lower_buf.len);
    for (message[0..slice_len], 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..slice_len];

    const retryable_phrases = [_][]const u8{
        // OpenAI / kimi / openai-compatible "engine overloaded"
        "overloaded",
        "engine is currently",
        "try again later",
        "try again shortly",
        "temporarily",
        // Rate limits across providers
        "rate limit",
        "rate_limit",
        "ratelimit",
        "too many requests",
        "quota exceeded for now",
        // Generic server-side blips
        "service unavailable",
        "server is busy",
        "server error",
        "internal server error",
        "internal error",
        "bad gateway",
        "gateway timeout",
        "timeout",
        "timed out",
        "upstream connect error",
        // Anthropic-flavoured
        "api_overloaded",
        "api error",
    };
    for (retryable_phrases) |phrase| {
        if (std.mem.indexOf(u8, lower, phrase) != null) return .retryable;
    }

    if (code.len > 0) {
        const retryable_codes = [_][]const u8{
            "rate_limited",
            "rate_limit_exceeded",
            "engine_overloaded",
            "overloaded_error",
            "server_error",
            "service_unavailable",
            "internal_error",
            "internal_server_error",
            "bad_gateway",
            "gateway_timeout",
            "timeout",
        };
        for (retryable_codes) |c| {
            if (std.ascii.eqlIgnoreCase(code, c)) return .retryable;
        }
    }

    return .terminal;
}

/// Extract the first text from a model response, falling back to duping `raw` on parse failure.
/// On allocation failure of the dupe fallback, frees `raw` before returning the error so the
/// caller cannot leak it through `try`. On success the caller still owns `raw` AND the returned
/// text (same invariant as `extractFirstText`).
pub fn extractFirstTextOrDupeRaw(allocator: std.mem.Allocator, raw: []u8) ![]u8 {
    return extractFirstText(allocator, raw) catch blk: {
        break :blk allocator.dupe(u8, raw) catch |err| {
            allocator.free(raw);
            return err;
        };
    };
}

pub fn callHttpJson(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
) ![]u8 {
    return callHttp(allocator, .POST, url, headers, body, timeout_ms);
}

pub fn callHttpJsonWithPolicy(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
    policy: egress.Policy,
) ![]u8 {
    return callHttpWithPolicy(allocator, .POST, url, headers, body, timeout_ms, policy);
}

pub fn callHttpJsonStream(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
) ![]u8 {
    const raw = try callHttpJson(allocator, url, headers, body, timeout_ms);
    defer allocator.free(raw);

    return parseSseText(allocator, raw);
}

/// Free a slice of ModelInfo values and all their owned strings.
/// Shared across all provider adapters to eliminate duplication.
pub fn freeModelInfos(allocator: std.mem.Allocator, models: []const types.ModelInfo) void {
    for (models) |m| {
        allocator.free(m.id);
        allocator.free(m.provider);
    }
    allocator.free(models);
}

/// Free every ModelInfo currently in the list AND deinit its backing
/// storage. Designed for the `errdefer` of a provider's staticModels /
/// parseDiscoveredModels — the old pattern of `defer out.deinit()`
/// leaked every already-appended model's id/provider dupes on error.
pub fn freeAndDeinitModelList(
    out: *std.array_list.Managed(types.ModelInfo),
    allocator: std.mem.Allocator,
) void {
    for (out.items) |m| {
        allocator.free(m.id);
        allocator.free(m.provider);
    }
    out.deinit();
}

/// Append a {id, provider, context_window} model row to `out` in a
/// leak-safe way. Previous per-provider code did
///     try out.append(.{ .id = try dupe, .provider = try dupe, ... });
/// which leaks id_dupe if provider_dupe OOMs, and leaks both if append
/// OOMs. This helper reserves capacity first so the final append is
/// infallible, and uses an iteration-scoped errdefer so a mid-row OOM
/// releases the in-hand dupe before the caller's outer errdefer takes
/// over.
pub fn appendModelInfoOwned(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(types.ModelInfo),
    id: []const u8,
    provider: []const u8,
    context_window: usize,
) !void {
    try out.ensureUnusedCapacity(1);
    const id_dupe = try allocator.dupe(u8, id);
    errdefer allocator.free(id_dupe);
    const provider_dupe = try allocator.dupe(u8, provider);
    out.appendAssumeCapacity(.{
        .id = id_dupe,
        .provider = provider_dupe,
        .context_window = context_window,
    });
}

/// Check if the API response was truncated due to hitting max_output_tokens.
/// Returns true if any choice has finish_reason "length".
pub fn isResponseTruncated(allocator: std.mem.Allocator, response_json: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const obj = parsed.value.object;

    // OpenAI / OpenAI-compatible: choices[0].finish_reason == "length"
    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                const reason = first.object.get("finish_reason") orelse return false;
                if (reason == .string) return std.mem.eql(u8, reason.string, "length");
            }
        }
    }

    // Anthropic: stop_reason == "max_tokens" (top-level field)
    if (obj.get("stop_reason")) |stop_reason| {
        if (stop_reason == .string) return std.mem.eql(u8, stop_reason.string, "max_tokens");
    }

    return false;
}

/// Scan a raw SSE stream body for a `"finish_reason":"length"` marker
/// emitted by any chunk. Used by the streaming path, which assembles
/// content deltas before we see the final chunk's finish_reason.
/// Some providers (Moonshot/Kimi among them) sometimes drop the final
/// chunk entirely or mark it `"stop"` even when output was cut, so
/// callers should also consult `looksLikeMidSentenceTruncation` on
/// the assembled text as a heuristic fallback.
pub fn isStreamingResponseTruncated(raw_stream: []const u8) bool {
    return std.mem.indexOf(u8, raw_stream, "\"finish_reason\":\"length\"") != null or
        std.mem.indexOf(u8, raw_stream, "\"finish_reason\": \"length\"") != null;
}

/// Heuristic: does this assistant text look like it was cut off mid-
/// sentence or mid-word? Returns true only when the text is long enough
/// to be meaningful (>= 40 chars) AND ends in a state that a well-formed
/// completion almost never does.
///
/// Real-world case that prompted this: Moonshot Kimi via OpenAI-compat
/// sometimes closes the SSE stream after 30-50 content tokens with
/// finish_reason "stop" even though the sentence is clearly unfinished
/// ("Here's a comprehensive breakdown of techniques and t"). Without
/// this heuristic zcode had no signal to auto-continue and the user
/// saw a dangling mid-word reply.
///
/// Conservative by design: only triggers on the strongest signals
/// (trailing alphanumeric character, odd number of code fences, open
/// markdown emphasis) so natural "Done." / "Let me know." endings are
/// preserved. False positives cost a wasted continuation turn; false
/// negatives cost a visibly broken reply, which is worse for UX.
pub fn looksLikeMidSentenceTruncation(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 40) return false;

    // Open-and-unclosed fenced code block: odd count of ``` markers.
    if (oddOccurrences(trimmed, "```")) return true;

    // A clean end almost always terminates with one of these shapes:
    //   - Terminal sentence punctuation (.  !  ?)
    //   - A closing bracket/quote/backtick that balances an opener
    //   - A colon/semicolon (enumeration preamble)
    //   - A closing code fence (handled above)
    const last = trimmed[trimmed.len - 1];
    switch (last) {
        '.', '!', '?', ')', ']', '}', '"', '\'', '`', ':', ';' => return false,
        else => {},
    }

    // Trailing alphanumeric character without any terminal punctuation
    // in the last ~40 chars is the strongest mid-word signal.
    if (std.ascii.isAlphanumeric(last)) {
        const tail_start = if (trimmed.len > 40) trimmed.len - 40 else 0;
        const tail = trimmed[tail_start..];
        if (std.mem.indexOfAny(u8, tail, ".!?") == null) return true;
    }

    return false;
}

/// Count occurrences of `needle` in `haystack` and return true when the
/// count is odd. Used to detect unclosed fenced code blocks.
fn oddOccurrences(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor + needle.len <= haystack.len) {
        if (std.mem.indexOf(u8, haystack[cursor..], needle)) |rel| {
            count += 1;
            cursor += rel + needle.len;
        } else break;
    }
    return (count & 1) == 1;
}

/// Append OpenAI-format tools array (and optional tool_choice) to a
/// JSON request body buffer. Splices `,"tools":[...]` and, when
/// `tool_choice` is provided, `,"tool_choice":...` before the closing }.
pub fn appendToolsToBody(body: *std_io.StringBuilder, schemas: []const types.ToolSchema) void {
    appendToolsAndChoiceToBody(body, schemas, null);
}

/// Append OpenAI-style `response_format` to a JSON body for structured
/// output. `schema_json` must be a valid JSON object literal (the
/// caller's JSON schema). Splices `,"response_format":{...}` before
/// the closing `}`. Silently no-ops on malformed buffers.
pub fn appendResponseSchemaToBody(
    body: *std_io.StringBuilder,
    schema_json: ?[]const u8,
    schema_name: []const u8,
) void {
    const schema = schema_json orelse return;
    if (schema.len == 0) return;
    if (body.items().len == 0) return;
    if (body.items()[body.items().len - 1] != '}') return;

    body.shrinkRetainingCapacity(body.items().len - 1);
    const w = body.writer();
    w.writeAll(",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"") catch return;
    extractors.writeJsonEscapedString(body, schema_name);
    w.writeAll("\",\"strict\":true,\"schema\":") catch return;
    w.writeAll(schema) catch return;
    w.writeAll("}}}") catch return;
}

pub fn appendToolsAndChoiceToBody(
    body: *std_io.StringBuilder,
    schemas: []const types.ToolSchema,
    tool_choice: ?[]const u8,
) void {
    if (schemas.len == 0 and tool_choice == null) return;
    if (body.items().len == 0) return;

    // Remove trailing }
    if (body.items()[body.items().len - 1] == '}') {
        body.shrinkRetainingCapacity(body.items().len - 1);
    } else return;

    const w = body.writer();

    if (schemas.len > 0) {
        w.writeAll(",\"tools\":[") catch return;
        for (schemas, 0..) |schema, idx| {
            if (idx > 0) w.writeByte(',') catch return;
            w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"") catch return;
            extractors.writeJsonEscapedString(body, schema.name);
            w.writeAll("\",\"description\":\"") catch return;
            extractors.writeJsonEscapedString(body, schema.description);
            w.writeAll("\",\"parameters\":") catch return;
            w.writeAll(schema.json_schema) catch return;
            w.writeAll("}}") catch return;
        }
        w.writeAll("]") catch return;
    }

    if (tool_choice) |choice| {
        // OpenAI accepts "auto" / "none" / "required" as bare strings,
        // or {"type":"function","function":{"name":"<name>"}} to force.
        // Map zcode's "any" to "required" for cross-provider symmetry.
        w.writeAll(",\"tool_choice\":") catch return;
        if (std.mem.eql(u8, choice, "auto") or std.mem.eql(u8, choice, "none")) {
            w.writeAll("\"") catch return;
            w.writeAll(choice) catch return;
            w.writeAll("\"") catch return;
        } else if (std.mem.eql(u8, choice, "any") or std.mem.eql(u8, choice, "required")) {
            w.writeAll("\"required\"") catch return;
        } else {
            w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"") catch return;
            extractors.writeJsonEscapedString(body, choice);
            w.writeAll("\"}}") catch return;
        }
    }

    w.writeAll("}") catch return;
    return;
}

/// Build a multi-turn messages JSON array from ModelRequest history.
/// Used by OpenAI-compatible providers (openai, local, groq, deepseek,
/// azure, openrouter) to construct proper role-alternating message arrays.
///
/// When history is non-empty:
///   [system, ...history_turns..., user(current_turn)]
/// When history is empty (backwards compat):
///   [system, user(full_prompt)]
///
/// Writes the complete `"messages":[...]` JSON fragment (without the key).
pub fn writeMultiTurnMessages(writer: anytype, request: *const types.ModelRequest) !void {
    try writer.writeAll("[");

    var msg_count: usize = 0;

    // System message
    if (request.system_prompt.len > 0) {
        try writer.writeAll("{\"role\":\"system\",\"content\":");
        try writer.print("{f}", .{std.json.fmt(request.system_prompt, .{})});
        try writer.writeAll("}");
        msg_count += 1;
    }

    if (request.history.len > 0) {
        // Multi-turn: emit each history turn as a separate message.
        // Tool turns are folded into user messages since OpenAI doesn't
        // have a "tool" role in the basic chat API (function calling uses
        // a different mechanism).
        for (request.history) |turn| {
            if (msg_count > 0) try writer.writeAll(",");
            const role = switch (turn.role) {
                .user => "user",
                .assistant => "assistant",
                .system => "system",
                .tool => "user", // tool results go as user messages
            };
            // Check for image content blocks (from Read tool on image files)
            if (std.mem.indexOf(u8, turn.content, "<zcode-image ") != null) {
                try writer.print("{{\"role\":\"{s}\",\"content\":[", .{role});
                try writeContentWithImages(writer, turn.content);
                try writer.writeAll("]}");
            } else {
                try writer.print("{{\"role\":\"{s}\",\"content\":", .{role});
                try writer.print("{f}", .{std.json.fmt(turn.content, .{})});
                try writer.writeAll("}");
            }
            msg_count += 1;
        }

        // Final user message: extract the current turn from the prompt.
        // The prompt contains [TOOLS]...[HISTORY]...[CONTEXT]...[USER]...
        // We want just the [USER] section + any [CONTEXT] for the final msg.
        const user_turn = extractCurrentUserTurn(request.prompt);
        if (user_turn.len > 0) {
            if (msg_count > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":\"user\",\"content\":");
            try writer.print("{f}", .{std.json.fmt(user_turn, .{})});
            try writer.writeAll("}");
        }
    } else {
        // No history: send full prompt as single user message (backwards compat)
        if (msg_count > 0) try writer.writeAll(",");
        try writer.writeAll("{\"role\":\"user\",\"content\":");
        try writer.print("{f}", .{std.json.fmt(request.prompt, .{})});
        try writer.writeAll("}");
    }

    try writer.writeAll("]");
}

/// Parsed <zcode-image ...> tag contents. `pre_text` is the content
/// before the image, `media_type` and `base64_data` describe the image
/// itself, `consumed` is the number of bytes consumed (pre_text + tag +
/// body + close-tag). If no image is present, returns null.
pub const ImageSegment = struct {
    pre_text: []const u8,
    media_type: []const u8,
    base64_data: []const u8,
    consumed: usize,
};

/// Try to parse the next `<zcode-image media_type="..."...>...data...</zcode-image>`
/// block starting anywhere in `content`. Returns null if none found or the
/// tag is malformed (caller falls back to emitting content as plain text).
pub fn nextImageSegment(content: []const u8) ?ImageSegment {
    const rel_start = std.mem.indexOf(u8, content, "<zcode-image ") orelse return null;
    const tag_end_rel = std.mem.indexOf(u8, content[rel_start..], ">\n") orelse return null;
    const tag = content[rel_start .. rel_start + tag_end_rel];

    const mt_start = std.mem.indexOf(u8, tag, "media_type=\"") orelse return null;
    const mt_val_start = mt_start + "media_type=\"".len;
    const mt_end_rel = std.mem.indexOf(u8, tag[mt_val_start..], "\"") orelse return null;
    const media_type = tag[mt_val_start .. mt_val_start + mt_end_rel];

    const data_start = rel_start + tag_end_rel + 2; // skip ">\n"
    const close_rel = std.mem.indexOf(u8, content[data_start..], "\n</zcode-image>") orelse return null;
    const base64_data = content[data_start .. data_start + close_rel];
    const consumed = data_start + close_rel + "\n</zcode-image>".len;

    return .{
        .pre_text = content[0..rel_start],
        .media_type = media_type,
        .base64_data = base64_data,
        .consumed = consumed,
    };
}

/// Write message content that may contain <zcode-image> blocks.
/// Splits the content into text and image content blocks for
/// providers that support vision (OpenAI image_url format).
fn writeContentWithImages(writer: anytype, content: []const u8) !void {
    var remaining = content;
    var first = true;

    while (nextImageSegment(remaining)) |seg| {
        if (seg.pre_text.len > 0) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try writer.print("{f}", .{std.json.fmt(seg.pre_text, .{})});
            try writer.writeAll("}");
            first = false;
        }

        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
        try writer.writeAll(seg.media_type);
        try writer.writeAll(";base64,");
        try writer.writeAll(seg.base64_data);
        try writer.writeAll("\"}}");
        first = false;

        remaining = remaining[seg.consumed..];
    }

    if (remaining.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writer.print("{f}", .{std.json.fmt(remaining, .{})});
        try writer.writeAll("}");
    }
}

/// Anthropic vision block emitter: emits alternating
/// `{"type":"text","text":...}` and
/// `{"type":"image","source":{"type":"base64","media_type":...,"data":...}}`
/// entries to form a content array. Caller wraps with `[...]`.
pub fn writeContentWithImagesAnthropic(writer: anytype, content: []const u8) !void {
    var remaining = content;
    var first = true;

    while (nextImageSegment(remaining)) |seg| {
        if (seg.pre_text.len > 0) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try writer.print("{f}", .{std.json.fmt(seg.pre_text, .{})});
            try writer.writeAll("}");
            first = false;
        }

        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
        try writer.print("{f}", .{std.json.fmt(seg.media_type, .{})});
        try writer.writeAll(",\"data\":");
        try writer.print("{f}", .{std.json.fmt(seg.base64_data, .{})});
        try writer.writeAll("}}");
        first = false;

        remaining = remaining[seg.consumed..];
    }

    if (remaining.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writer.print("{f}", .{std.json.fmt(remaining, .{})});
        try writer.writeAll("}");
    }
}

/// Gemini vision part emitter: emits alternating
/// `{"text":"..."}` and `{"inline_data":{"mime_type":"...","data":"..."}}`
/// entries for use inside a `"parts":[...]` array.
pub fn writeContentWithImagesGemini(writer: anytype, content: []const u8) !void {
    var remaining = content;
    var first = true;

    while (nextImageSegment(remaining)) |seg| {
        if (seg.pre_text.len > 0) {
            if (!first) try writer.writeAll(",");
            try writer.writeAll("{\"text\":");
            try writer.print("{f}", .{std.json.fmt(seg.pre_text, .{})});
            try writer.writeAll("}");
            first = false;
        }

        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"inline_data\":{\"mime_type\":");
        try writer.print("{f}", .{std.json.fmt(seg.media_type, .{})});
        try writer.writeAll(",\"data\":");
        try writer.print("{f}", .{std.json.fmt(seg.base64_data, .{})});
        try writer.writeAll("}}");
        first = false;

        remaining = remaining[seg.consumed..];
    }

    if (remaining.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("{\"text\":");
        try writer.print("{f}", .{std.json.fmt(remaining, .{})});
        try writer.writeAll("}");
    }
}

/// True if `content` contains at least one well-formed `<zcode-image>` block.
pub fn hasImageSegment(content: []const u8) bool {
    return nextImageSegment(content) != null;
}

/// Extract the current user turn from the prompt text. Returns everything
/// from [USER]\n to the end, plus any [CONTEXT] section before it.
/// Falls back to the full prompt if no [USER] marker is found.
fn extractCurrentUserTurn(prompt: []const u8) []const u8 {
    // Try to find [CONTEXT] and [USER] markers
    const context_start = std.mem.indexOf(u8, prompt, "[CONTEXT]\n");
    const user_start = std.mem.indexOf(u8, prompt, "[USER]\n");

    if (context_start != null and user_start != null) {
        // Return from [CONTEXT] to end (includes both context and user turn)
        return prompt[@min(context_start.?, user_start.?)..];
    }
    if (user_start) |us| {
        return prompt[us..];
    }
    // No markers found -- return full prompt
    return prompt;
}

const testing = std.testing;

test "extractCurrentUserTurn finds USER section" {
    const prompt = "[TOOLS]\nsome tools\n[HISTORY]\nuser: hi\n[CONTEXT]\ngit status\n[USER]\nhello world\n";
    const turn = extractCurrentUserTurn(prompt);
    try testing.expect(std.mem.startsWith(u8, turn, "[CONTEXT]\n"));
    try testing.expect(std.mem.indexOf(u8, turn, "hello world") != null);
}

test "extractCurrentUserTurn returns full prompt when no markers" {
    const prompt = "just a plain prompt";
    try testing.expectEqualStrings(prompt, extractCurrentUserTurn(prompt));
}

test "mapHttpStatusError classifies overloaded as ServerOverloaded" {
    try testing.expect(mapHttpStatusError(529, "{\"error\":\"overloaded\"}") == error.ServerOverloaded);
    try testing.expect(mapHttpStatusError(503, "service unavailable") == error.ServerOverloaded);
    // generic 5xx stays transport
    try testing.expect(mapHttpStatusError(500, "boom") == error.HttpTransport);
}

test "mapHttpStatusError classifies common provider failures" {
    try testing.expect(mapHttpStatusError(402, "{\"error\":\"payment required\"}") == error.InsufficientBalance);
    try testing.expect(mapHttpStatusError(429, "{\"error\":\"rate limit\"}") == error.RateLimited);
    try testing.expect(mapHttpStatusError(401, "{\"error\":\"unauthorized\"}") == error.AuthenticationFailed);
    try testing.expect(mapHttpStatusError(500, "{\"error\":\"server\"}") == error.HttpTransport);
    try testing.expect(mapHttpStatusError(418, "{\"error\":\"teapot\"}") == error.HttpStatusCode);
    try testing.expect(mapHttpStatusError(400, "{\"error\":\"insufficient balance\"}") == error.InsufficientBalance);
}

test "sanitizeHtmlPayload + mapHttpStatusError recovers error class from CDN error pages" {
    // A CloudFlare 502 arrives as a full HTML page. After sanitization, the
    // only remaining text is the <title>, which should feed into status-code
    // classification without tripping the substring heuristics.
    const cloudflare_502 =
        "<!DOCTYPE html><html><head><title>Error 502 Bad Gateway</title></head><body>Lorem ipsum</body></html>";
    const sanitized = sanitizeHtmlPayload(cloudflare_502);
    try testing.expectEqualStrings("Error 502 Bad Gateway", sanitized);
    // 502 falls through status checks (>= 500) into HttpTransport -- which is retryable.
    try testing.expect(mapHttpStatusError(502, sanitized) == error.HttpTransport);
}

test "sanitizeHtmlPayload strips HTML before rate-limit classification" {
    // A "rate limit" phrase buried inside an HTML body should NOT trigger
    // RateLimited classification once the payload is sanitized down to the title.
    const raw =
        "<!DOCTYPE html><html><head><title>Too Many Requests</title></head><body>You may have hit a rate limit. Retry later.</body></html>";
    const sanitized = sanitizeHtmlPayload(raw);
    try testing.expectEqualStrings("Too Many Requests", sanitized);
    // 429 still classifies by status code first -- so RateLimited wins.
    try testing.expect(mapHttpStatusError(429, sanitized) == error.RateLimited);
    // But at status 503 (Service Unavailable), the sanitized title "Too Many Requests"
    // should NOT trigger RateLimited -- 503 now classifies as ServerOverloaded.
    try testing.expect(mapHttpStatusError(503, sanitized) == error.ServerOverloaded);
}

test "mapHttpStatusError classifies 408/409/413 and leaves 400/429/529 unchanged" {
    // 408 Request Timeout reuses ConnectionTimeout (retriable).
    try testing.expect(mapHttpStatusError(408, "request timeout") == error.ConnectionTimeout);
    // 409 Conflict is transient -> HttpTransport (retriable).
    try testing.expect(mapHttpStatusError(409, "conflict") == error.HttpTransport);
    // 413 Payload Too Large is its own class so reactive compaction can trigger.
    try testing.expect(mapHttpStatusError(413, "payload too large") == error.RequestTooLarge);
    // Unchanged classifications.
    try testing.expect(mapHttpStatusError(429, "{\"error\":\"rate limit\"}") == error.RateLimited);
    try testing.expect(mapHttpStatusError(503, "service unavailable") == error.ServerOverloaded);
    try testing.expect(mapHttpStatusError(529, "{\"error\":\"overloaded\"}") == error.ServerOverloaded);
    try testing.expect(mapHttpStatusError(400, "{\"error\":\"bad request\"}") == error.HttpStatusCode);
}

test "mapHttpStatusError maps a 400 prompt-too-long body to RequestTooLarge" {
    // Anthropic's direct API returns the over-budget rejection on a 400, not a
    // 413, so reactive compaction must trigger off the body text (Task 7.5).
    try testing.expect(mapHttpStatusError(
        400,
        "{\"error\":{\"message\":\"prompt is too long: 137500 tokens > 135000 maximum\"}}",
    ) == error.RequestTooLarge);
    // A 400 without that body stays a generic HttpStatusCode (unchanged).
    try testing.expect(mapHttpStatusError(400, "{\"error\":\"invalid_request\"}") == error.HttpStatusCode);
}

test "mapHttpStatusError maps a 400 max_tokens context-overflow body to MaxTokensOverflow" {
    // The direct API returns this over-budget rejection on a 400; it is
    // recoverable by lowering max_tokens, distinct from prompt-too-long which
    // reduces history (Task 7.6).
    try testing.expect(mapHttpStatusError(
        400,
        "{\"error\":{\"message\":\"input length and `max_tokens` exceed context limit: 188059 + 20000 > 200000\"}}",
    ) == error.MaxTokensOverflow);
    // A plain 400 stays a generic HttpStatusCode.
    try testing.expect(mapHttpStatusError(400, "{\"error\":\"invalid_request\"}") == error.HttpStatusCode);
}

test "shouldRetryHttpError retries only transient failures" {
    try testing.expect(shouldRetryHttpError(error.HttpTransport));
    try testing.expect(shouldRetryHttpError(error.ServerOverloaded));
    try testing.expect(!shouldRetryHttpError(error.HttpStatusCode));
    try testing.expect(!shouldRetryHttpError(error.RateLimited));
    try testing.expect(!shouldRetryHttpError(error.InsufficientBalance));
    try testing.expect(!shouldRetryHttpError(error.AuthenticationFailed));
    // 413 maps to RequestTooLarge, which is not retriable at the HTTP layer.
    try testing.expect(!shouldRetryHttpError(error.RequestTooLarge));
}

test "shouldRetryHttpErrorWithHeaders obeys x-should-retry header" {
    // x-should-retry: false on an otherwise non-retriable error -> no retry.
    const no_retry = [_]HeaderPair{.{ .name = "x-should-retry", .value = "false" }};
    try testing.expect(!shouldRetryHttpErrorWithHeaders(error.HttpStatusCode, &no_retry));

    // x-should-retry: false carve-out: genuine server overload / transport still retries.
    try testing.expect(shouldRetryHttpErrorWithHeaders(error.ServerOverloaded, &no_retry));
    try testing.expect(shouldRetryHttpErrorWithHeaders(error.HttpTransport, &no_retry));

    // x-should-retry: true forces a retry even for a normally non-retriable error.
    const force_retry = [_]HeaderPair{.{ .name = "x-should-retry", .value = "true" }};
    try testing.expect(shouldRetryHttpErrorWithHeaders(error.HttpStatusCode, &force_retry));

    // Case-insensitive header value handling.
    const force_retry_caps = [_]HeaderPair{.{ .name = "x-should-retry", .value = "TRUE" }};
    try testing.expect(shouldRetryHttpErrorWithHeaders(error.HttpStatusCode, &force_retry_caps));

    // Absent header -> falls back to the status-based logic (unchanged).
    const empty: []const HeaderPair = &.{};
    try testing.expect(shouldRetryHttpErrorWithHeaders(error.ConnectionTimeout, empty));
    try testing.expect(!shouldRetryHttpErrorWithHeaders(error.HttpStatusCode, empty));
}

test "describeProviderError surfaces actionable text for RequestTooLarge" {
    const msg = describeProviderError(error.RequestTooLarge);
    try testing.expect(msg.len > 0);
    try testing.expect(std.mem.indexOf(u8, msg, "413") != null);
}

test "describeProviderError surfaces actionable text for MaxTokensOverflow" {
    const msg = describeProviderError(error.MaxTokensOverflow);
    try testing.expect(msg.len > 0);
    try testing.expect(std.mem.indexOf(u8, msg, "max_tokens") != null);
}

test "classifyCurlExit maps SSL/TLS exit codes to SslError" {
    // Representative SSL/cert/cipher/pinning codes from `man curl`.
    try testing.expectEqual(error.SslError, classifyCurlExit(35, ""));
    try testing.expectEqual(error.SslError, classifyCurlExit(51, ""));
    try testing.expectEqual(error.SslError, classifyCurlExit(60, ""));
    try testing.expectEqual(error.SslError, classifyCurlExit(77, ""));
    // An unrelated curl exit (22, HTTP error returned by --fail) is not SSL.
    try testing.expectEqual(error.HttpTransport, classifyCurlExit(22, ""));
}

test "classifyCurlExit keeps timeout / refused / DNS classification" {
    try testing.expectEqual(error.ConnectionTimeout, classifyCurlExit(28, ""));
    try testing.expectEqual(error.ConnectionRefused, classifyCurlExit(7, ""));
    try testing.expectEqual(error.DnsResolutionFailed, classifyCurlExit(6, ""));
    // stderr fallback: a generic exit code whose message points at TLS.
    try testing.expectEqual(error.SslError, classifyCurlExit(35, ""));
    try testing.expectEqual(error.SslError, classifyCurlExit(1, "SSL certificate problem: unable to get local issuer certificate"));
    // A generic non-zero exit with no telling stderr falls through to transport.
    try testing.expectEqual(error.HttpTransport, classifyCurlExit(1, "some unrelated failure"));
}

test "describeProviderError surfaces a CA-bundle / proxy hint for SslError" {
    const msg = describeProviderError(error.SslError);
    try testing.expect(msg.len > 0);
    try testing.expect(std.mem.indexOf(u8, msg, "CURL_CA_BUNDLE") != null or
        std.mem.indexOf(u8, msg, "SSL_CERT_FILE") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "proxy") != null);
}

test "isStreamingResponseTruncated detects length finish_reason in SSE body" {
    const truncated_stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n" ++
        "data: [DONE]\n";
    try testing.expect(isStreamingResponseTruncated(truncated_stream));

    // Space variant also handled
    const with_space =
        "data: {\"choices\":[{\"finish_reason\": \"length\"}]}\n";
    try testing.expect(isStreamingResponseTruncated(with_space));
}

test "isStreamingResponseTruncated returns false on clean stop" {
    const clean_stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"done.\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n" ++
        "data: [DONE]\n";
    try testing.expect(!isStreamingResponseTruncated(clean_stream));
}

test "looksLikeMidSentenceTruncation catches mid-word Kimi-style cutoff" {
    // Real user report: kimi-k2.5 truncated at 44 tokens mid-word.
    const cut = "OSINT (Open Source Intelligence) techniques for researching a person involve gathering publicly available information from various sources. Here's a comprehensive breakdown of techniques and t";
    try testing.expect(looksLikeMidSentenceTruncation(cut));
}

test "looksLikeMidSentenceTruncation accepts normal sentence endings" {
    try testing.expect(!looksLikeMidSentenceTruncation("Here's a complete answer with a proper period ending the thought."));
    try testing.expect(!looksLikeMidSentenceTruncation("Do you want to continue with the next step?"));
    try testing.expect(!looksLikeMidSentenceTruncation("Done! Let me know if you need more."));
    try testing.expect(!looksLikeMidSentenceTruncation("Here is the result: `value` (paren-terminated phrase)"));
}

test "looksLikeMidSentenceTruncation flags unclosed code fences" {
    const unclosed = "Here's some code:\n```python\ndef foo():\n    return 42\nThis is where it stops without closing the fence";
    try testing.expect(looksLikeMidSentenceTruncation(unclosed));
    const balanced = "Here's some code:\n```python\ndef foo():\n    return 42\n```\nAll closed up cleanly.";
    try testing.expect(!looksLikeMidSentenceTruncation(balanced));
}

test "looksLikeMidSentenceTruncation ignores short replies" {
    // Short replies ("OK", "Yes", "Done", etc) are not long enough to
    // reliably distinguish truncation from brevity.
    try testing.expect(!looksLikeMidSentenceTruncation("OK"));
    try testing.expect(!looksLikeMidSentenceTruncation("Yes"));
    try testing.expect(!looksLikeMidSentenceTruncation("Done"));
    try testing.expect(!looksLikeMidSentenceTruncation("Short reply without period"));
}

test "looksLikeMidSentenceTruncation tolerates trailing punctuation list items" {
    // List-like text ending in a colon (common enumeration preamble) is OK.
    try testing.expect(!looksLikeMidSentenceTruncation("Here are the options to consider, each well-documented:"));
}

test "appendResponseSchemaToBody emits OpenAI response_format" {
    const allocator = testing.allocator;

    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try body.appendSlice("{\"model\":\"gpt-4o\"}");

    appendResponseSchemaToBody(
        &body,
        "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
        "person",
    );

    try testing.expect(std.mem.indexOf(u8, body.items(), "\"response_format\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.items(), "\"json_schema\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.items(), "\"name\":\"person\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.items(), "\"strict\":true") != null);

    // Null schema: no-op
    var body2 = std_io.StringBuilder.init(allocator);
    defer body2.deinit();
    try body2.appendSlice("{\"m\":1}");
    appendResponseSchemaToBody(&body2, null, "x");
    try testing.expect(std.mem.indexOf(u8, body2.items(), "\"response_format\"") == null);

    // Empty string: no-op
    var body3 = std_io.StringBuilder.init(allocator);
    defer body3.deinit();
    try body3.appendSlice("{\"m\":1}");
    appendResponseSchemaToBody(&body3, "", "x");
    try testing.expect(std.mem.indexOf(u8, body3.items(), "\"response_format\"") == null);

    // Verify the emitted body is valid JSON round-trip.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "appendToolsAndChoiceToBody emits OpenAI tool_choice shapes" {
    const allocator = testing.allocator;
    const schemas = [_]types.ToolSchema{.{ .name = "search", .description = "x", .json_schema = "{}" }};

    // "auto" stays bare string.
    var body1 = std_io.StringBuilder.init(allocator);
    defer body1.deinit();
    try body1.appendSlice("{\"m\":1}");
    appendToolsAndChoiceToBody(&body1, schemas[0..], "auto");
    try testing.expect(std.mem.indexOf(u8, body1.items(), "\"tool_choice\":\"auto\"") != null);

    // "any" maps to "required".
    var body2 = std_io.StringBuilder.init(allocator);
    defer body2.deinit();
    try body2.appendSlice("{\"m\":1}");
    appendToolsAndChoiceToBody(&body2, schemas[0..], "any");
    try testing.expect(std.mem.indexOf(u8, body2.items(), "\"tool_choice\":\"required\"") != null);

    // Tool name becomes object form.
    var body3 = std_io.StringBuilder.init(allocator);
    defer body3.deinit();
    try body3.appendSlice("{\"m\":1}");
    appendToolsAndChoiceToBody(&body3, schemas[0..], "search");
    try testing.expect(std.mem.indexOf(u8, body3.items(), "\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"search\"}}") != null);

    // null tool_choice: no field emitted.
    var body4 = std_io.StringBuilder.init(allocator);
    defer body4.deinit();
    try body4.appendSlice("{\"m\":1}");
    appendToolsAndChoiceToBody(&body4, schemas[0..], null);
    try testing.expect(std.mem.indexOf(u8, body4.items(), "\"tool_choice\"") == null);
}

test "appendToolsToBody escapes tool names" {
    const allocator = testing.allocator;

    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try body.appendSlice("{\"model\":\"test\"}");

    const schemas = [_]types.ToolSchema{.{
        .name = "mcp::demo::say\"hi",
        .description = "quoted name",
        .json_schema = "{\"type\":\"object\"}",
    }};
    appendToolsToBody(&body, schemas[0..]);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body.items(), .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools") orelse return error.TestUnexpectedResult;
    const first = tools.array.items[0];
    const function_obj = first.object.get("function") orelse return error.TestUnexpectedResult;
    const name = function_obj.object.get("name") orelse return error.TestUnexpectedResult;

    try testing.expectEqualStrings("mcp::demo::say\"hi", name.string);
}

test "classifyProviderErrorText flags overloaded engines as retryable" {
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("The engine is currently overloaded, please try again later", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Server overloaded", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Try again later", ""),
    );
}

test "classifyProviderErrorText flags rate limits and 5xx blips as retryable" {
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Rate limit exceeded", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Too Many Requests", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Service Unavailable", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Internal server error", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("upstream connect error", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("Request timed out", ""),
    );
}

test "classifyProviderErrorText flags retryable codes case-insensitively" {
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("", "engine_overloaded"),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("", "RATE_LIMITED"),
    );
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyProviderErrorText("", "service_unavailable"),
    );
}

test "classifyProviderErrorText returns terminal for permanent failures" {
    try testing.expectEqual(
        ErrorBodyKind.terminal,
        classifyProviderErrorText("Invalid API key provided", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.terminal,
        classifyProviderErrorText("model not found", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.terminal,
        classifyProviderErrorText("invalid request: messages must be non-empty", ""),
    );
    try testing.expectEqual(
        ErrorBodyKind.terminal,
        classifyProviderErrorText("", "invalid_api_key"),
    );
}

test "classifyErrorBody recognises the kimi overloaded envelope" {
    const body =
        \\{"error":{"message":"The engine is currently overloaded, please try again later","type":"server_error"}}
    ;
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyErrorBody(testing.allocator, body),
    );
}

test "classifyErrorBody returns none on a successful chat completion" {
    const body =
        \\{"id":"x","choices":[{"message":{"role":"assistant","content":"hi"}}]}
    ;
    try testing.expectEqual(
        ErrorBodyKind.none,
        classifyErrorBody(testing.allocator, body),
    );
}

test "classifyErrorBody returns none when choices coexist with a stray error field" {
    // Some providers echo a deprecation warning under `error` while
    // still returning a real completion in `choices`. The classifier
    // must NOT treat that as a retryable failure.
    const body =
        \\{"id":"x","error":{"message":"deprecated"},"choices":[{"message":{"role":"assistant","content":"ok"}}]}
    ;
    try testing.expectEqual(
        ErrorBodyKind.none,
        classifyErrorBody(testing.allocator, body),
    );
}

test "classifyErrorBody returns none on malformed json" {
    try testing.expectEqual(
        ErrorBodyKind.none,
        classifyErrorBody(testing.allocator, "not json at all"),
    );
}

test "classifyErrorBody flags Anthropic-style overloaded_error" {
    const body =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
    ;
    try testing.expectEqual(
        ErrorBodyKind.retryable,
        classifyErrorBody(testing.allocator, body),
    );
}

test "classifyErrorBody flags terminal auth errors" {
    const body =
        \\{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}
    ;
    try testing.expectEqual(
        ErrorBodyKind.terminal,
        classifyErrorBody(testing.allocator, body),
    );
}

test "classifyErrorBody returns none when error field is empty" {
    const body =
        \\{"error":{}}
    ;
    try testing.expectEqual(
        ErrorBodyKind.none,
        classifyErrorBody(testing.allocator, body),
    );
}

test "recordTerminalError increments rate-limit rejections only on RateLimited" {
    const m = metrics_mod.globalMetrics();
    const rl_before = m.getCounter(metrics_mod.Names.rate_limit_rejections);
    const err_before = m.getCounter(metrics_mod.Names.provider_errors_total);

    // A non-rate-limit terminal error bumps provider_errors but not the
    // rate-limit counter.
    recordTerminalError(m, error.HttpTransport);
    try testing.expectEqual(rl_before, m.getCounter(metrics_mod.Names.rate_limit_rejections));
    try testing.expectEqual(err_before + 1, m.getCounter(metrics_mod.Names.provider_errors_total));

    // A RateLimited terminal error bumps both.
    recordTerminalError(m, error.RateLimited);
    try testing.expectEqual(rl_before + 1, m.getCounter(metrics_mod.Names.rate_limit_rejections));
    try testing.expectEqual(err_before + 2, m.getCounter(metrics_mod.Names.provider_errors_total));
}

test "callHttpWithResilience sets the circuit-breaker-state gauge to open when the breaker is open" {
    // Force the breaker open so allowRequest() short-circuits before any
    // network call (so the test is hermetic). The wiring must mirror the
    // breaker's stateValue() into the gauge regardless of network access.
    var cb = circuit_breaker_mod.CircuitBreaker.init(1, 3600);
    cb.recordFailure(); // closed -> open (threshold 1)
    try testing.expect(cb.state == .open);

    const result = callHttpWithResilience(
        testing.allocator,
        .GET,
        "http://127.0.0.1:1/v1/never",
        &.{},
        null,
        100,
        0,
        &cb,
    );
    try testing.expectError(error.CircuitBreakerOpen, result);

    const m = metrics_mod.globalMetrics();
    // stateValue() open == 1; allowRequest() on an open-but-cooled breaker
    // would flip to half_open, but the 1-hour cooldown keeps it open here.
    try testing.expectEqual(@as(f64, 1.0), m.getGauge(metrics_mod.Names.circuit_breaker_state));
}

test "requestCancel records reason and bool, beginNewRequest resets both (task 22.1)" {
    // Baseline: a fresh request clears both the bool and the reason tag.
    beginNewRequest();
    try testing.expect(!isCancelRequested());
    try testing.expectEqual(CancelReason.none, cancelReason());

    // A submit-interrupt sets the reason AND the cancel bool (killActiveChild
    // sets the bool; with no active child pid it is a no-op kill).
    requestCancel(.submit_interrupt);
    try testing.expect(isCancelRequested());
    try testing.expectEqual(CancelReason.submit_interrupt, cancelReason());

    // reset (via beginNewRequest) returns both to baseline.
    beginNewRequest();
    try testing.expect(!isCancelRequested());
    try testing.expectEqual(CancelReason.none, cancelReason());

    // A hard interrupt records the hard reason.
    requestCancel(.hard);
    try testing.expect(isCancelRequested());
    try testing.expectEqual(CancelReason.hard, cancelReason());

    // Leave the global signal clean for any later test in the run.
    beginNewRequest();
}
