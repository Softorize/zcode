//! Dangerous-key approval gate for managed config files (settings-03).
//!
//! An admin-pushed managed.toml (and its managed.d drop-ins) can carry keys
//! that execute shell commands or hijack inference routing: command-helper
//! keys (apiKeyHelper / statusLine / ...), env vars NOT on the safe list
//! (ANTHROPIC_BASE_URL, HTTP_PROXY, ...), and a `[hooks]` section. Before
//! such a file is allowed to take effect, the reference shows an accept/reject
//! dialog and exits(1) on reject; it caches the last-approved set so an
//! unchanged file does not re-prompt every launch, and skips the prompt in
//! non-interactive mode.
//!
//! Ported from:
//!   - claude-code-main/src/services/remoteManagedSettings/securityCheck.tsx:22-73
//!   - claude-code-main/src/components/ManagedSettingsSecurityDialog/utils.ts:24-117
//!   - claude-code-main/src/utils/managedEnvConstants.ts:75-191
//!     (DANGEROUS_SHELL_SETTINGS + SAFE_ENV_VARS).
//!
//! This module is pure classification + cache I/O so it is unit-testable. The
//! interactive prompt and the exit(1) live in main.zig (the prompt path is hard
//! to unit-test; everything decidable lives here).

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("std_io.zig");

/// Command-helper config keys that run a shell command. zcode does not yet
/// expose any of these as scalar config keys (statusLine is segment-based and
/// the *Helper keys belong to a future auth subsystem), so this list is
/// forward-looking: if settings-08's statusLine helper ever lands it is
/// automatically gated because mergeManagedFileInto scans the raw key names.
/// Names match the reference (camelCase) so a managed file written for the
/// reference is classified identically.
///
/// Ported from managedEnvConstants.ts:75-82 (DANGEROUS_SHELL_SETTINGS).
pub const DANGEROUS_SHELL_SETTINGS = [_][]const u8{
    "apiKeyHelper",
    "awsAuthRefresh",
    "awsCredentialExport",
    "gcpAuthRefresh",
    "otelHeadersHelper",
    "statusLine",
};

/// Environment variables that are safe to apply from a managed file without an
/// approval prompt. Any env var NOT on this list is treated as dangerous (it
/// could redirect traffic to an attacker-controlled server, trust a hostile
/// cert, or switch to an attacker project). Matched case-insensitively against
/// the upper-cased key, mirroring the reference's `key.toUpperCase()` lookup.
///
/// Ported verbatim from managedEnvConstants.ts:108-191 (SAFE_ENV_VARS).
pub const SAFE_ENV_VARS = [_][]const u8{
    "ANTHROPIC_CUSTOM_HEADERS",
    "ANTHROPIC_CUSTOM_MODEL_OPTION",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_DESCRIPTION",
    "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "AWS_DEFAULT_REGION",
    "AWS_PROFILE",
    "AWS_REGION",
    "BASH_DEFAULT_TIMEOUT_MS",
    "BASH_MAX_OUTPUT_LENGTH",
    "BASH_MAX_TIMEOUT_MS",
    "CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR",
    "CLAUDE_CODE_API_KEY_HELPER_TTL_MS",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
    "CLAUDE_CODE_DISABLE_TERMINAL_TITLE",
    "CLAUDE_CODE_ENABLE_TELEMETRY",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
    "CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL",
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
    "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_VERTEX",
    "DISABLE_AUTOUPDATER",
    "DISABLE_BUG_COMMAND",
    "DISABLE_COST_WARNINGS",
    "DISABLE_ERROR_REPORTING",
    "DISABLE_FEEDBACK_COMMAND",
    "DISABLE_TELEMETRY",
    "ENABLE_TOOL_SEARCH",
    "MAX_MCP_OUTPUT_TOKENS",
    "MAX_THINKING_TOKENS",
    "MCP_TIMEOUT",
    "MCP_TOOL_TIMEOUT",
    "OTEL_EXPORTER_OTLP_HEADERS",
    "OTEL_EXPORTER_OTLP_LOGS_HEADERS",
    "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL",
    "OTEL_EXPORTER_OTLP_METRICS_CLIENT_CERTIFICATE",
    "OTEL_EXPORTER_OTLP_METRICS_CLIENT_KEY",
    "OTEL_EXPORTER_OTLP_METRICS_HEADERS",
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL",
    "OTEL_EXPORTER_OTLP_PROTOCOL",
    "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
    "OTEL_LOG_TOOL_DETAILS",
    "OTEL_LOG_USER_PROMPTS",
    "OTEL_LOGS_EXPORT_INTERVAL",
    "OTEL_LOGS_EXPORTER",
    "OTEL_METRIC_EXPORT_INTERVAL",
    "OTEL_METRICS_EXPORTER",
    "OTEL_METRICS_INCLUDE_ACCOUNT_UUID",
    "OTEL_METRICS_INCLUDE_SESSION_ID",
    "OTEL_METRICS_INCLUDE_VERSION",
    "OTEL_RESOURCE_ATTRIBUTES",
    "USE_BUILTIN_RIPGREP",
    "VERTEX_REGION_CLAUDE_3_5_HAIKU",
    "VERTEX_REGION_CLAUDE_3_5_SONNET",
    "VERTEX_REGION_CLAUDE_3_7_SONNET",
    "VERTEX_REGION_CLAUDE_4_0_OPUS",
    "VERTEX_REGION_CLAUDE_4_0_SONNET",
    "VERTEX_REGION_CLAUDE_4_1_OPUS",
    "VERTEX_REGION_CLAUDE_4_5_SONNET",
    "VERTEX_REGION_CLAUDE_4_6_SONNET",
    "VERTEX_REGION_CLAUDE_HAIKU_4_5",
};

/// True when `key` names a command-helper setting that runs a shell command.
/// Case-sensitive: the reference list is camelCase and a managed file targeting
/// the reference uses that exact casing.
pub fn isDangerousShellSetting(key: []const u8) bool {
    for (DANGEROUS_SHELL_SETTINGS) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

/// True when `key` is on the safe env-var list (case-insensitive, matching the
/// reference's `SAFE_ENV_VARS.has(key.toUpperCase())`).
pub fn isSafeEnvVar(key: []const u8) bool {
    for (SAFE_ENV_VARS) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    return false;
}

/// The collected set of dangerous keys found across a managed file + its
/// drop-ins. Names only -- values are never stored or shown (the reference is
/// explicit that only names are surfaced). The three buckets mirror the
/// reference's DangerousSettings { shellSettings, envVars, hasHooks }.
pub const DangerousSummary = struct {
    allocator: std.mem.Allocator,
    shell_settings: std.array_list.Managed([]u8),
    unsafe_env: std.array_list.Managed([]u8),
    has_hooks: bool,

    pub fn init(allocator: std.mem.Allocator) DangerousSummary {
        return .{
            .allocator = allocator,
            .shell_settings = std.array_list.Managed([]u8).init(allocator),
            .unsafe_env = std.array_list.Managed([]u8).init(allocator),
            .has_hooks = false,
        };
    }

    pub fn deinit(self: *DangerousSummary) void {
        for (self.shell_settings.items) |s| self.allocator.free(s);
        for (self.unsafe_env.items) |s| self.allocator.free(s);
        self.shell_settings.deinit();
        self.unsafe_env.deinit();
    }

    fn appendUnique(self: *DangerousSummary, list: *std.array_list.Managed([]u8), name: []const u8) !void {
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        const copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(copy);
        try list.append(copy);
    }

    /// Note a scalar managed key. If it names a dangerous command-helper, it is
    /// recorded; otherwise ignored (ordinary scalar config is not dangerous).
    pub fn noteScalarKey(self: *DangerousSummary, key: []const u8) !void {
        if (isDangerousShellSetting(key)) {
            try self.appendUnique(&self.shell_settings, key);
        }
    }

    /// Note a key found inside a managed `[env]` table. Non-safe env vars are
    /// recorded as dangerous (they can redirect routing / trust hostile certs).
    pub fn noteEnvKey(self: *DangerousSummary, key: []const u8) !void {
        if (!isSafeEnvVar(key)) {
            try self.appendUnique(&self.unsafe_env, key);
        }
    }

    /// Note that the managed file contains a `[hooks]` section.
    pub fn noteHooks(self: *DangerousSummary) void {
        self.has_hooks = true;
    }

    /// True when anything dangerous was collected. Mirrors hasDangerousSettings.
    pub fn hasDangerous(self: *const DangerousSummary) bool {
        return self.shell_settings.items.len > 0 or
            self.unsafe_env.items.len > 0 or
            self.has_hooks;
    }

    /// A human-readable list of dangerous names (NEVER values), for the prompt.
    /// Caller owns the returned slice and each entry. Mirrors
    /// formatDangerousSettingsList.
    pub fn formatDangerousList(self: *const DangerousSummary, allocator: std.mem.Allocator) ![][]u8 {
        var out = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit();
        }
        for (self.shell_settings.items) |k| try out.append(try allocator.dupe(u8, k));
        for (self.unsafe_env.items) |k| try out.append(try allocator.dupe(u8, k));
        if (self.has_hooks) try out.append(try allocator.dupe(u8, "hooks"));
        return out.toOwnedSlice();
    }

    /// Stable fingerprint of the dangerous set: sorted names + a hooks marker,
    /// joined with newlines. Two summaries with the same dangerous keys (in any
    /// ingestion order) produce the same fingerprint, so reordering drop-ins
    /// does not trigger a re-prompt. Values are never included. Mirrors the
    /// JSON-compare in hasDangerousSettingsChanged, but order-stable.
    pub fn fingerprint(self: *const DangerousSummary, allocator: std.mem.Allocator) ![]u8 {
        var names = std.array_list.Managed([]const u8).init(allocator);
        defer names.deinit();
        for (self.shell_settings.items) |k| try names.append(k);
        for (self.unsafe_env.items) |k| try names.append(k);
        if (self.has_hooks) try names.append("hooks");

        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        for (names.items, 0..) |n, i| {
            if (i > 0) try out.append('\n');
            try out.appendSlice(n);
        }
        return out.toOwnedSlice();
    }
};

/// True when the new summary is dangerous AND differs from the cached
/// fingerprint (so a prompt is warranted). When the new summary has nothing
/// dangerous, returns false regardless of the cache. A null/empty cache with a
/// dangerous new summary returns true (first sighting). Mirrors
/// hasDangerousSettingsChanged.
pub fn hasChanged(allocator: std.mem.Allocator, cached_fingerprint: ?[]const u8, current: *const DangerousSummary) !bool {
    if (!current.hasDangerous()) return false;
    const cached = cached_fingerprint orelse return true;
    const fp = try current.fingerprint(allocator);
    defer allocator.free(fp);
    return !std.mem.eql(u8, std.mem.trim(u8, cached, " \t\r\n"), fp);
}

/// Textual scan of a raw managed-file body for dangerous keys. Used by the unit
/// tests and as a fallback; the live path feeds the summary key-by-key during
/// ingestion so it does not re-parse. Tracks the current `[section]` so an env
/// key is classified against SAFE_ENV_VARS and a scalar key against the
/// shell-setting list. A `[hooks]` section sets has_hooks.
pub fn extractFromBody(allocator: std.mem.Allocator, body: []const u8) !DangerousSummary {
    var summary = DangerousSummary.init(allocator);
    errdefer summary.deinit();

    var current_section: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.startsWith(u8, line, "[")) {
            if (std.mem.indexOfScalar(u8, line, ']')) |close_idx| {
                const section = std.mem.trim(u8, line[1..close_idx], " \t");
                current_section = section;
                if (std.mem.eql(u8, section, "hooks")) summary.noteHooks();
            } else {
                current_section = null;
            }
            continue;
        }
        const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_idx], " \t");
        if (key.len == 0) continue;
        if (current_section) |section| {
            if (std.mem.eql(u8, section, "env")) {
                try summary.noteEnvKey(key);
                continue;
            }
        }
        try summary.noteScalarKey(key);
    }
    return summary;
}

// ---------------------------------------------------------------------------
// Approval-fingerprint cache.
//
// The last-approved fingerprint is stored under the user state dir so an
// unchanged managed file does not re-prompt every launch. Written atomically
// (tmp + rename) so a crash mid-write cannot corrupt it.
// ---------------------------------------------------------------------------

/// Read the cached approved fingerprint, or null if absent/unreadable.
/// Unreadable cache is treated as "no cache" so a corrupt file fails toward
/// prompting (the security-safe direction), not toward silent approval.
pub fn readCachedFingerprint(allocator: std.mem.Allocator, cache_path: []const u8) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, cache_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return null,
    };
    return bytes;
}

/// Atomically write the approved fingerprint to the cache.
pub fn writeCachedFingerprint(allocator: std.mem.Allocator, cache_path: []const u8, fingerprint_bytes: []const u8) !void {
    if (std.fs.path.dirname(cache_path)) |dir| {
        @import("paths.zig").ensureDir(dir) catch {};
    }
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, fingerprint_bytes);
        file.sync(rt.io) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, cache_path, rt.io);
}

const testing = std.testing;

test "isDangerousShellSetting matches the camelCase helper keys" {
    try testing.expect(isDangerousShellSetting("statusLine"));
    try testing.expect(isDangerousShellSetting("apiKeyHelper"));
    try testing.expect(!isDangerousShellSetting("default_model"));
    // Case-sensitive: a lowercased variant is not a match.
    try testing.expect(!isDangerousShellSetting("statusline"));
}

test "isSafeEnvVar is case-insensitive and rejects routing vars" {
    try testing.expect(isSafeEnvVar("ANTHROPIC_MODEL"));
    try testing.expect(isSafeEnvVar("anthropic_model"));
    try testing.expect(isSafeEnvVar("VERTEX_REGION_CLAUDE_4_5_SONNET"));
    try testing.expect(!isSafeEnvVar("HTTP_PROXY"));
    try testing.expect(!isSafeEnvVar("ANTHROPIC_BASE_URL"));
    try testing.expect(!isSafeEnvVar("ANTHROPIC_API_KEY"));
}

test "extractDangerous flags a [hooks] section" {
    var summary = try extractFromBody(testing.allocator, "[hooks]\nPreToolUse = \"echo hi\"\n");
    defer summary.deinit();
    try testing.expect(summary.has_hooks);
    try testing.expect(summary.hasDangerous());
}

test "extractDangerous flags a non-safe env var but not a safe one" {
    var unsafe = try extractFromBody(testing.allocator, "[env]\nHTTP_PROXY = \"http://10.0.0.1\"\n");
    defer unsafe.deinit();
    try testing.expect(unsafe.hasDangerous());
    try testing.expectEqual(@as(usize, 1), unsafe.unsafe_env.items.len);
    try testing.expectEqualStrings("HTTP_PROXY", unsafe.unsafe_env.items[0]);

    var safe = try extractFromBody(testing.allocator, "[env]\nANTHROPIC_MODEL = \"claude-x\"\n");
    defer safe.deinit();
    try testing.expect(!safe.hasDangerous());
    try testing.expectEqual(@as(usize, 0), safe.unsafe_env.items.len);
}

test "extractDangerous flags a command-helper scalar key" {
    var summary = try extractFromBody(testing.allocator, "statusLine = \"/usr/local/bin/mystatus\"\n");
    defer summary.deinit();
    try testing.expect(summary.hasDangerous());
    try testing.expectEqual(@as(usize, 1), summary.shell_settings.items.len);
    try testing.expectEqualStrings("statusLine", summary.shell_settings.items[0]);
}

test "hasChanged is false when fingerprint matches, true when a new key appears" {
    const allocator = testing.allocator;

    var summary = try extractFromBody(allocator, "[env]\nHTTP_PROXY = \"x\"\n");
    defer summary.deinit();

    const fp = try summary.fingerprint(allocator);
    defer allocator.free(fp);

    // Cached == current -> no change.
    try testing.expect(!try hasChanged(allocator, fp, &summary));

    // A new dangerous key appears -> changed vs the old cache.
    var bigger = try extractFromBody(allocator, "[hooks]\nx = \"y\"\n[env]\nHTTP_PROXY = \"x\"\n");
    defer bigger.deinit();
    try testing.expect(try hasChanged(allocator, fp, &bigger));

    // No cache + dangerous -> changed (first sighting).
    try testing.expect(try hasChanged(allocator, null, &summary));

    // Nothing dangerous -> never changed.
    var empty = try extractFromBody(allocator, "[env]\nANTHROPIC_MODEL = \"x\"\n");
    defer empty.deinit();
    try testing.expect(!try hasChanged(allocator, null, &empty));
}

test "formatDangerousList emits names only, never values" {
    const allocator = testing.allocator;
    var summary = try extractFromBody(allocator, "[env]\nHTTP_PROXY = \"http://secret-host:9999\"\n[hooks]\nx = \"y\"\n");
    defer summary.deinit();

    const names = try summary.formatDangerousList(allocator);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var saw_proxy = false;
    var saw_hooks = false;
    for (names) |n| {
        // The value substring must never leak into the displayed list.
        try testing.expect(std.mem.indexOf(u8, n, "secret-host") == null);
        try testing.expect(std.mem.indexOf(u8, n, "9999") == null);
        if (std.mem.eql(u8, n, "HTTP_PROXY")) saw_proxy = true;
        if (std.mem.eql(u8, n, "hooks")) saw_hooks = true;
    }
    try testing.expect(saw_proxy);
    try testing.expect(saw_hooks);
}

test "fingerprint is order-stable across ingestion order" {
    const allocator = testing.allocator;
    var a = try extractFromBody(allocator, "[env]\nHTTP_PROXY = \"x\"\nNO_PROXY = \"y\"\n");
    defer a.deinit();
    var b = try extractFromBody(allocator, "[env]\nNO_PROXY = \"y\"\nHTTP_PROXY = \"x\"\n");
    defer b.deinit();

    const fa = try a.fingerprint(allocator);
    defer allocator.free(fa);
    const fb = try b.fingerprint(allocator);
    defer allocator.free(fb);
    try testing.expectEqualStrings(fa, fb);
}

test "fingerprint cache round-trips through a tmp file" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(dir_path);
    const cache_path = try std.fs.path.join(allocator, &.{ dir_path, "managed_approval.fp" });
    defer allocator.free(cache_path);

    // Absent cache reads as null.
    try testing.expect(try readCachedFingerprint(allocator, cache_path) == null);

    try writeCachedFingerprint(allocator, cache_path, "statusLine\nHTTP_PROXY");
    const read_back = (try readCachedFingerprint(allocator, cache_path)).?;
    defer allocator.free(read_back);
    try testing.expectEqualStrings("statusLine\nHTTP_PROXY", read_back);
}
