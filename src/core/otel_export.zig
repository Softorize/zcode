//! Configurable OTLP push exporter (analytics-03 / phase-16.18).
//!
//! Reference: claude-code-main `instrumentation.ts:121` wires the OTEL
//! exporter from the standard `OTEL_EXPORTER_OTLP_*` environment
//! variables and periodically pushes metrics to a remote collector.
//!
//! Our pull-based `/otel` endpoint (remote_daemon.zig) and the
//! `renderOtlpJson` renderer (core/otel.zig) already exist; this module
//! adds the missing PUSH side: read the env config, POST the rendered
//! OTLP JSON to `<endpoint>/v1/metrics`, and optionally run a background
//! flush loop.
//!
//! Design notes:
//!   - Pushing metrics to an arbitrary remote is opt-in: the loop only
//!     runs when the endpoint env var is set AND `cloud_telemetry_opt_in`
//!     is true. A misconfigured collector cannot silently exfiltrate
//!     telemetry.
//!   - The actual POST is routed through `providers/common.callHttpJson`,
//!     which already runs every URL through the central egress chokepoint
//!     (core/egress.zig). So the endpoint must pass the egress allowlist /
//!     SSRF guard just like any provider call.
//!   - Only `http/json` protocol is supported initially -- our renderer
//!     emits OTLP JSON and that is the simplest interoperable path.
//!   - `exportOnce` takes an injectable transport function so the request
//!     construction (endpoint, headers, body) is testable without a live
//!     network round-trip. Production callers pass `defaultTransport`.

const std = @import("std");
const env_mod = @import("env.zig");
const otel = @import("otel.zig");
const http_common = @import("../providers/common.zig");
const clock = @import("clock.zig");

/// Default flush interval when `OTEL_METRIC_EXPORT_INTERVAL` is unset (ms).
pub const DEFAULT_EXPORT_INTERVAL_MS: u64 = 60_000;

/// Default per-request timeout for a push, in ms.
pub const DEFAULT_TIMEOUT_MS: u32 = 5_000;

pub const Protocol = enum {
    http_json,

    pub fn fromEnv(value: []const u8) Protocol {
        // The reference accepts http/protobuf and grpc as well; we only
        // emit OTLP JSON so we map everything to http_json. An explicit
        // "http/json" obviously maps here too.
        _ = value;
        return .http_json;
    }
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Parsed `OTEL_EXPORTER_OTLP_*` configuration. All owned slices are
/// allocated from the allocator passed to `parseFromEnvMap` and freed by
/// `deinit`.
pub const ExporterConfig = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    headers: []Header,
    protocol: Protocol,
    interval_ms: u64,

    pub fn deinit(self: *ExporterConfig) void {
        self.allocator.free(self.endpoint);
        for (self.headers) |h| {
            self.allocator.free(h.key);
            self.allocator.free(h.value);
        }
        self.allocator.free(self.headers);
    }

    /// The full metrics push URL: `<endpoint>/v1/metrics`, trimming a
    /// trailing slash on the endpoint so we never emit `//v1/metrics`.
    pub fn metricsUrl(self: *const ExporterConfig, allocator: std.mem.Allocator) ![]u8 {
        return buildMetricsUrl(allocator, self.endpoint);
    }
};

pub fn buildMetricsUrl(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, endpoint, "/");
    return std.fmt.allocPrint(allocator, "{s}/v1/metrics", .{trimmed});
}

/// Parse the `OTEL_EXPORTER_OTLP_*` env vars from an explicit getter.
/// `getter` returns the raw value for a name, or null when unset. This
/// indirection lets tests inject values without touching the process
/// environment. Returns null when no endpoint is configured (the export
/// path is inert in that case).
pub fn parseFromGetter(
    allocator: std.mem.Allocator,
    getter: *const fn (name: []const u8) ?[]const u8,
) !?ExporterConfig {
    // Per the OTEL spec the metrics-specific override takes precedence
    // over the generic OTLP endpoint.
    const raw_endpoint = getter("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") orelse
        getter("OTEL_EXPORTER_OTLP_ENDPOINT") orelse return null;
    const endpoint_trimmed = std.mem.trim(u8, raw_endpoint, " \t\r\n");
    if (endpoint_trimmed.len == 0) return null;

    const endpoint = try allocator.dupe(u8, endpoint_trimmed);
    errdefer allocator.free(endpoint);

    const headers_csv = getter("OTEL_EXPORTER_OTLP_METRICS_HEADERS") orelse
        getter("OTEL_EXPORTER_OTLP_HEADERS") orelse "";
    const headers = try parseHeadersCsv(allocator, headers_csv);
    errdefer freeHeaders(allocator, headers);

    const protocol = if (getter("OTEL_EXPORTER_OTLP_PROTOCOL")) |p|
        Protocol.fromEnv(std.mem.trim(u8, p, " \t\r\n"))
    else
        Protocol.http_json;

    const interval_ms = if (getter("OTEL_METRIC_EXPORT_INTERVAL")) |iv|
        parseIntervalMs(std.mem.trim(u8, iv, " \t\r\n"))
    else
        DEFAULT_EXPORT_INTERVAL_MS;

    return ExporterConfig{
        .allocator = allocator,
        .endpoint = endpoint,
        .headers = headers,
        .protocol = protocol,
        .interval_ms = interval_ms,
    };
}

/// Parse from the real process environment via core/env.zig.
pub fn parseFromEnv(allocator: std.mem.Allocator) !?ExporterConfig {
    return parseFromGetter(allocator, &env_mod.getenv);
}

fn parseIntervalMs(value: []const u8) u64 {
    if (value.len == 0) return DEFAULT_EXPORT_INTERVAL_MS;
    return std.fmt.parseInt(u64, value, 10) catch DEFAULT_EXPORT_INTERVAL_MS;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |h| {
        allocator.free(h.key);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

/// Parse the comma-separated `key=value` header list defined by the OTEL
/// spec, e.g. `api-key=secret,x-tenant=acme`. Whitespace around keys and
/// values is trimmed. Entries without an `=` or with an empty key are
/// skipped. The returned slice and its strings are owned by the caller.
pub fn parseHeadersCsv(allocator: std.mem.Allocator, csv: []const u8) ![]Header {
    var list = std.array_list.Managed(Header).init(allocator);
    errdefer {
        for (list.items) |h| {
            allocator.free(h.key);
            allocator.free(h.value);
        }
        list.deinit();
    }

    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t\r\n");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], " \t\r\n");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t\r\n");
        if (key.len == 0) continue;

        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, value);
        try list.append(.{ .key = owned_key, .value = owned_value });
    }

    return list.toOwnedSlice();
}

/// A transport POSTs `body` (JSON) to `url` with the given `Header: value`
/// header lines (already formatted), returning the response body owned by
/// the allocator. The production transport is `defaultTransport`; tests
/// inject a capturing fake.
pub const Transport = *const fn (
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
) anyerror![]u8;

/// Production transport: POST through the central HTTP chokepoint, which
/// applies the egress allowlist / SSRF guard before any bytes leave.
pub fn defaultTransport(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const []const u8,
    body: []const u8,
    timeout_ms: u32,
) anyerror![]u8 {
    return http_common.callHttpJson(allocator, url, headers, body, timeout_ms);
}

/// Render the current global metrics as OTLP JSON and POST them once to
/// `<config.endpoint>/v1/metrics` using `transport`. Best-effort: any
/// transport error is returned to the caller, which decides whether to
/// log-and-continue (the push loop does).
pub fn exportOnce(
    allocator: std.mem.Allocator,
    config: *const ExporterConfig,
    transport: Transport,
) !void {
    const body = try otel.renderOtlpJson(allocator);
    defer allocator.free(body);

    const url = try config.metricsUrl(allocator);
    defer allocator.free(url);

    // Always send Content-Type plus any user-configured headers. Format
    // each as a `Key: value` line for the curl/http chokepoint.
    var header_lines = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (header_lines.items) |line| allocator.free(line);
        header_lines.deinit();
    }
    try header_lines.append(try allocator.dupe(u8, "Content-Type: application/json"));
    for (config.headers) |h| {
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.key, h.value });
        try header_lines.append(line);
    }

    const resp = try transport(allocator, url, header_lines.items, body, DEFAULT_TIMEOUT_MS);
    allocator.free(resp);
}

/// Decide whether the background push loop should run. Requires both an
/// endpoint to be configured AND the user to have opted into cloud
/// telemetry. Mirrors the reference's opt-in gating so metrics are never
/// pushed to a remote without explicit consent.
pub fn isPushEnabled(config: ?*const ExporterConfig, cloud_telemetry_opt_in: bool) bool {
    const cfg = config orelse return false;
    if (cfg.endpoint.len == 0) return false;
    return cloud_telemetry_opt_in;
}

// --- Background push loop --------------------------------------------
//
// Spawned only when isPushEnabled() returns true. Pushes one batch every
// `config.interval_ms`, polling a stop flag frequently so shutdown is
// responsive, and flushes one final batch on stop. The thread is
// joinable so a short one-shot run still pushes a final batch on exit.

pub const PushLoop = struct {
    config: *const ExporterConfig,
    transport: Transport,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *PushLoop) void {
        if (self.thread != null) return;
        self.stop.store(false, .release);
        self.thread = std.Thread.spawn(.{}, loopMain, .{self}) catch null;
    }

    /// Signal stop, push a final batch, and join. Safe to call when the
    /// loop never started.
    pub fn stopAndFlush(self: *PushLoop) void {
        self.stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn loopMain(self: *PushLoop) void {
        const gpa = self.config.allocator;
        while (!self.stop.load(.acquire)) {
            // Sleep in small slices so a stop request is honored within
            // ~250ms rather than waiting a full interval.
            var slept: u64 = 0;
            while (slept < self.config.interval_ms and !self.stop.load(.acquire)) {
                const slice_ms: u64 = @min(@as(u64, 250), self.config.interval_ms - slept);
                std.Thread.sleep(slice_ms * std.time.ns_per_ms);
                slept += slice_ms;
            }
            if (self.stop.load(.acquire)) break;
            exportOnce(gpa, self.config, self.transport) catch |err| {
                std.log.warn("otel_export: push failed: {s}", .{@errorName(err)});
            };
        }
        // Final flush on shutdown so a short run still delivers a batch.
        exportOnce(gpa, self.config, self.transport) catch |err| {
            std.log.warn("otel_export: final push failed: {s}", .{@errorName(err)});
        };
    }
};

// --- Tests ------------------------------------------------------------

const testing = std.testing;

// A getter backed by a fixed map, for deterministic env parsing tests.
const TestEnv = struct {
    var pairs: []const [2][]const u8 = &.{};

    fn get(name: []const u8) ?[]const u8 {
        for (pairs) |p| {
            if (std.mem.eql(u8, p[0], name)) return p[1];
        }
        return null;
    }
};

test "parseFromGetter returns null when no endpoint configured" {
    TestEnv.pairs = &.{};
    const cfg = try parseFromGetter(testing.allocator, &TestEnv.get);
    try testing.expect(cfg == null);
}

test "parseFromGetter reads endpoint and comma-separated headers" {
    const pairs = [_][2][]const u8{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "https://collector.example.com" },
        .{ "OTEL_EXPORTER_OTLP_HEADERS", " api-key=secret , x-tenant = acme " },
        .{ "OTEL_METRIC_EXPORT_INTERVAL", "1500" },
    };
    TestEnv.pairs = &pairs;

    var cfg = (try parseFromGetter(testing.allocator, &TestEnv.get)).?;
    defer cfg.deinit();

    try testing.expectEqualStrings("https://collector.example.com", cfg.endpoint);
    try testing.expectEqual(@as(usize, 2), cfg.headers.len);
    try testing.expectEqualStrings("api-key", cfg.headers[0].key);
    try testing.expectEqualStrings("secret", cfg.headers[0].value);
    try testing.expectEqualStrings("x-tenant", cfg.headers[1].key);
    try testing.expectEqualStrings("acme", cfg.headers[1].value);
    try testing.expectEqual(@as(u64, 1500), cfg.interval_ms);
    try testing.expectEqual(Protocol.http_json, cfg.protocol);
}

test "metrics-specific endpoint overrides the generic OTLP endpoint" {
    const pairs = [_][2][]const u8{
        .{ "OTEL_EXPORTER_OTLP_ENDPOINT", "https://generic.example.com" },
        .{ "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "https://metrics.example.com" },
    };
    TestEnv.pairs = &pairs;

    var cfg = (try parseFromGetter(testing.allocator, &TestEnv.get)).?;
    defer cfg.deinit();
    try testing.expectEqualStrings("https://metrics.example.com", cfg.endpoint);
    // No interval override -> default.
    try testing.expectEqual(DEFAULT_EXPORT_INTERVAL_MS, cfg.interval_ms);
}

test "parseHeadersCsv skips malformed entries" {
    const headers = try parseHeadersCsv(testing.allocator, "a=1,,no-equals,=novalue,b=2");
    defer freeHeaders(testing.allocator, headers);
    try testing.expectEqual(@as(usize, 2), headers.len);
    try testing.expectEqualStrings("a", headers[0].key);
    try testing.expectEqualStrings("1", headers[0].value);
    try testing.expectEqualStrings("b", headers[1].key);
    try testing.expectEqualStrings("2", headers[1].value);
}

test "buildMetricsUrl trims a trailing slash" {
    const a = try buildMetricsUrl(testing.allocator, "https://c.example.com");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("https://c.example.com/v1/metrics", a);

    const b = try buildMetricsUrl(testing.allocator, "https://c.example.com/");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("https://c.example.com/v1/metrics", b);
}

test "isPushEnabled requires endpoint and opt-in" {
    // No config -> disabled.
    try testing.expect(!isPushEnabled(null, true));

    var cfg = ExporterConfig{
        .allocator = testing.allocator,
        .endpoint = try testing.allocator.dupe(u8, "https://c.example.com"),
        .headers = try testing.allocator.alloc(Header, 0),
        .protocol = .http_json,
        .interval_ms = DEFAULT_EXPORT_INTERVAL_MS,
    };
    defer cfg.deinit();

    // Endpoint present but opt-out -> disabled.
    try testing.expect(!isPushEnabled(&cfg, false));
    // Endpoint present and opted-in -> enabled.
    try testing.expect(isPushEnabled(&cfg, true));
}

// Capturing fake transport: records the last POST so exportOnce can be
// asserted without a real network round-trip.
const CaptureTransport = struct {
    var last_url: [512]u8 = undefined;
    var last_url_len: usize = 0;
    var last_body: [4096]u8 = undefined;
    var last_body_len: usize = 0;
    var header_count: usize = 0;
    var saw_content_type: bool = false;
    var saw_api_key: bool = false;

    fn reset() void {
        last_url_len = 0;
        last_body_len = 0;
        header_count = 0;
        saw_content_type = false;
        saw_api_key = false;
    }

    fn post(
        allocator: std.mem.Allocator,
        req_url: []const u8,
        headers: []const []const u8,
        body: []const u8,
        timeout_ms: u32,
    ) anyerror![]u8 {
        _ = timeout_ms;
        @memcpy(last_url[0..req_url.len], req_url);
        last_url_len = req_url.len;
        @memcpy(last_body[0..body.len], body);
        last_body_len = body.len;
        header_count = headers.len;
        for (headers) |h| {
            if (std.mem.startsWith(u8, h, "Content-Type:")) saw_content_type = true;
            if (std.mem.startsWith(u8, h, "api-key:")) saw_api_key = true;
        }
        // Return an owned empty response (exportOnce frees it).
        return allocator.dupe(u8, "");
    }

    fn url() []const u8 {
        return last_url[0..last_url_len];
    }
    fn bodyText() []const u8 {
        return last_body[0..last_body_len];
    }
};

test "exportOnce posts OTLP body to the metrics endpoint with headers" {
    CaptureTransport.reset();

    var headers = try testing.allocator.alloc(Header, 1);
    headers[0] = .{
        .key = try testing.allocator.dupe(u8, "api-key"),
        .value = try testing.allocator.dupe(u8, "secret"),
    };
    var cfg = ExporterConfig{
        .allocator = testing.allocator,
        .endpoint = try testing.allocator.dupe(u8, "https://collector.example.com"),
        .headers = headers,
        .protocol = .http_json,
        .interval_ms = DEFAULT_EXPORT_INTERVAL_MS,
    };
    defer cfg.deinit();

    try exportOnce(testing.allocator, &cfg, &CaptureTransport.post);

    try testing.expectEqualStrings("https://collector.example.com/v1/metrics", CaptureTransport.url());
    // The body is the rendered OTLP JSON document.
    try testing.expect(std.mem.indexOf(u8, CaptureTransport.bodyText(), "resourceMetrics") != null);
    // Content-Type plus the one configured header.
    try testing.expectEqual(@as(usize, 2), CaptureTransport.header_count);
    try testing.expect(CaptureTransport.saw_content_type);
    try testing.expect(CaptureTransport.saw_api_key);
}
