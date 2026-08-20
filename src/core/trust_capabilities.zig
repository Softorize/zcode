//! First-run trust-dialog capability enumeration (ui-dialogs-01).
//!
//! On the first interactive session in an untrusted workspace, the reference
//! TrustDialog enumerates every trust-relevant dangerous capability detected in
//! the workspace before letting the user accept trust. This module is the pure
//! detector half: it reads the same workspace sources zcode already loads and
//! returns a struct listing which capabilities were detected and their source
//! names. It has no IO side effects beyond reading config/workspace files; it
//! never persists trust (that is `trust.allow`'s job) and never shows UI (that
//! is the overlay loop in `repl_overlay.zig`).
//!
//! Ported from:
//!   - claude-code-main/src/components/TrustDialog/TrustDialog.tsx:22-130
//!     (collects getMcpConfigsByScope("project"), getHooksSources(),
//!      getBashPermissionSources(), getApiKeyHelperSources(),
//!      getAwsCommandsSources(), getGcpCommandsSources(),
//!      getOtelHeadersHelperSources(), getDangerousEnvVarsSources(),
//!      plus hasSlashCommandBash / hasSkillsBash).
//!   - claude-code-main/src/screens/interactiveHelpers.tsx:131-144
//!     (fast path: only enumerated when trust has not been accepted).
//!
//! Redaction rule (matches formatDangerousSettingsList): the formatted body
//! lists capability NAMES / source paths only, never secret VALUES. A test
//! enforces this.

const std = @import("std");
const rt = @import("zcode_runtime");
const paths = @import("paths.zig");
const mcp_config = @import("mcp_config.zig");
const hook_config = @import("hook_config.zig");
const hook_event = @import("hook_event.zig");
const managed_security = @import("managed_security.zig");

/// Command-helper config keys that run a shell command, mirroring
/// `managed_security.DANGEROUS_SHELL_SETTINGS`. When one of these appears as a
/// top-level key in the workspace settings.json it is a dangerous capability
/// the user is about to trust. zcode does not yet surface most of these as
/// scalar config keys (see the note in `managed_security.zig`), so detection is
/// forward-looking but classified identically to a managed file.
const API_KEY_HELPER_KEY = "apiKeyHelper";
const AWS_AUTH_REFRESH_KEY = "awsAuthRefresh";
const AWS_CREDENTIAL_EXPORT_KEY = "awsCredentialExport";
const GCP_AUTH_REFRESH_KEY = "gcpAuthRefresh";
const OTEL_HEADERS_HELPER_KEY = "otelHeadersHelper";

/// Cap on a single workspace file (`.mcp.json` / `.claude/settings.json`).
/// `readFileAlloc(.limited(N))` returns `error.StreamTooLong` (not
/// `error.FileTooBig`) per the 0.16 migration notes; we treat an oversized file
/// as "nothing to enumerate" rather than failing the whole gate.
const MAX_SETTINGS_BYTES: usize = 4 * 1024 * 1024;

/// An environment variable name/value pair as supplied by the loaded config
/// (`config.EnvPair` has the same shape). Borrowed: the detector never frees
/// the caller's env entries.
pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

/// The set of trust-relevant dangerous capabilities detected in a workspace.
/// All owned slices are dup-owned and freed by `deinit`. Names / paths only --
/// never secret values (mirrors the reference's name-only enumeration).
pub const DetectedCapabilities = struct {
    allocator: std.mem.Allocator,
    /// Project-scope MCP server names found in `<cwd>/.mcp.json`.
    mcp_servers: [][]u8,
    /// Hook event names found in `<cwd>/.claude/settings.json`.
    hooks: [][]u8,
    /// Names of dangerous environment variables (any configured env var not on
    /// `managed_security.SAFE_ENV_VARS`). Names only, never values.
    dangerous_env_vars: [][]u8,
    has_api_key_helper: bool,
    aws_commands: bool,
    gcp_commands: bool,
    otel_headers_helper: bool,
    /// True when a slash command in the workspace can run bash. Forward-looking;
    /// zcode's command discovery does not yet flag this, so it stays false.
    slash_command_bash: bool,
    /// True when a skill in the workspace can run bash. Forward-looking; stays
    /// false until skill-bash detection lands.
    skills_bash: bool,

    pub fn deinit(self: *DetectedCapabilities) void {
        freeStrings(self.allocator, self.mcp_servers);
        freeStrings(self.allocator, self.hooks);
        freeStrings(self.allocator, self.dangerous_env_vars);
        self.* = undefined;
    }

    /// True when at least one dangerous capability was detected. The reference
    /// always shows the dialog when untrusted, but listing zero capabilities is
    /// allowed; this lets a caller decide whether the body is worth rendering.
    pub fn anyDetected(self: *const DetectedCapabilities) bool {
        return self.mcp_servers.len > 0 or
            self.hooks.len > 0 or
            self.dangerous_env_vars.len > 0 or
            self.has_api_key_helper or
            self.aws_commands or
            self.gcp_commands or
            self.otel_headers_helper or
            self.slash_command_bash or
            self.skills_bash;
    }

    /// A human-readable list of detected-capability lines (NAMES / paths only,
    /// NEVER values), one per detected capability, for the trust-gate body.
    /// Caller owns the returned slice and each entry. Mirrors the reference's
    /// name-only enumeration (formatDangerousSettingsList).
    pub fn formatBodyLines(self: *const DetectedCapabilities, allocator: std.mem.Allocator) ![][]u8 {
        var out = std.array_list.Managed([]u8).init(allocator);
        errdefer {
            for (out.items) |s| allocator.free(s);
            out.deinit();
        }

        for (self.mcp_servers) |name| {
            try out.append(try std.fmt.allocPrint(allocator, "MCP server: {s}", .{name}));
        }
        for (self.hooks) |name| {
            try out.append(try std.fmt.allocPrint(allocator, "Hook: {s}", .{name}));
        }
        for (self.dangerous_env_vars) |name| {
            // Name only -- the value is deliberately omitted so a secret never
            // leaks into the transcript.
            try out.append(try std.fmt.allocPrint(allocator, "Environment variable: {s}", .{name}));
        }
        if (self.has_api_key_helper) {
            try out.append(try allocator.dupe(u8, "API key helper command"));
        }
        if (self.aws_commands) {
            try out.append(try allocator.dupe(u8, "AWS credential command"));
        }
        if (self.gcp_commands) {
            try out.append(try allocator.dupe(u8, "GCP credential command"));
        }
        if (self.otel_headers_helper) {
            try out.append(try allocator.dupe(u8, "OTel headers helper command"));
        }
        if (self.slash_command_bash) {
            try out.append(try allocator.dupe(u8, "Slash command that runs bash"));
        }
        if (self.skills_bash) {
            try out.append(try allocator.dupe(u8, "Skill that runs bash"));
        }
        return out.toOwnedSlice();
    }
};

fn freeStrings(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |s| allocator.free(s);
    if (items.len > 0) allocator.free(items);
}

/// Detect every trust-relevant dangerous capability in `cwd`. `cwd` must be an
/// absolute workspace path (do NOT pass "." -- it is relative to the test
/// process CWD, not the tmp dir). `settings_env` is the loaded set of
/// settings-sourced env vars (e.g. `config.settings_env`); any env var NOT on
/// `managed_security.SAFE_ENV_VARS` is recorded as dangerous (name only).
///
/// Pure with respect to persistence: this reads `<cwd>/.mcp.json` and
/// `<cwd>/.claude/settings.json` but writes nothing and never touches the trust
/// store.
pub fn detect(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    settings_env: []const EnvVar,
) !DetectedCapabilities {
    var result = DetectedCapabilities{
        .allocator = allocator,
        .mcp_servers = &.{},
        .hooks = &.{},
        .dangerous_env_vars = &.{},
        .has_api_key_helper = false,
        .aws_commands = false,
        .gcp_commands = false,
        .otel_headers_helper = false,
        .slash_command_bash = false,
        .skills_bash = false,
    };
    errdefer result.deinit();

    result.mcp_servers = try detectMcpServers(allocator, cwd);
    result.hooks = try detectHooks(allocator, cwd);
    result.dangerous_env_vars = try detectDangerousEnv(allocator, settings_env);
    try detectShellHelpers(allocator, cwd, &result);

    return result;
}

/// Read `<cwd>/.mcp.json` (if present) and return the project-scope server
/// names. A missing or malformed file yields an empty list (the trust gate is a
/// best-effort enumeration, not a validator). Env expansion is disabled so we
/// never touch the live process environment.
fn detectMcpServers(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    const json_path = try std.fs.path.join(allocator, &.{ cwd, paths.mcpJsonName });
    defer allocator.free(json_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, json_path, allocator, .limited(MAX_SETTINGS_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        // StreamTooLong (not FileTooBig in 0.16): treat an oversized file as
        // "no enumerable servers" rather than failing the whole gate.
        error.StreamTooLong => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try mcp_config.parseMcpJson(allocator, bytes, .project, false);
    defer parsed.deinit(allocator);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (parsed.servers) |srv| {
        try out.append(try allocator.dupe(u8, srv.name));
    }
    return out.toOwnedSlice();
}

/// Read `<cwd>/.claude/settings.json` (if present) and return the distinct hook
/// event names configured there. A missing/malformed file yields an empty list.
fn detectHooks(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
    defer allocator.free(settings_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, settings_path, allocator, .limited(MAX_SETTINGS_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        error.StreamTooLong => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try hook_config.parse(allocator, bytes);
    defer parsed.deinit();

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (parsed.defs) |def| {
        const event_name = hook_event.canonicalName(def.event);
        // De-dup so two hooks on the same event surface once.
        var already = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, event_name)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try out.append(try allocator.dupe(u8, event_name));
    }
    return out.toOwnedSlice();
}

/// Classify each configured env var: any var NOT on `SAFE_ENV_VARS` is recorded
/// (name only) as a dangerous capability. Mirrors getDangerousEnvVarsSources.
fn detectDangerousEnv(allocator: std.mem.Allocator, settings_env: []const EnvVar) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (settings_env) |pair| {
        if (managed_security.isSafeEnvVar(pair.name)) continue;
        // De-dup.
        var already = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, pair.name)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try out.append(try allocator.dupe(u8, pair.name));
    }
    return out.toOwnedSlice();
}

/// Detect command-helper keys (apiKeyHelper / aws* / gcp* / otelHeadersHelper)
/// present as top-level keys in `<cwd>/.claude/settings.json`. These run a
/// shell command, so trusting the workspace trusts them. Names only.
fn detectShellHelpers(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    result: *DetectedCapabilities,
) !void {
    const settings_path = try std.fs.path.join(allocator, &.{ cwd, ".claude", "settings.json" });
    defer allocator.free(settings_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, settings_path, allocator, .limited(MAX_SETTINGS_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return,
        error.StreamTooLong => return,
        else => return err,
    };
    defer allocator.free(bytes);

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;

    if (hasNonEmptyString(root, API_KEY_HELPER_KEY)) result.has_api_key_helper = true;
    if (hasNonEmptyString(root, AWS_AUTH_REFRESH_KEY) or hasNonEmptyString(root, AWS_CREDENTIAL_EXPORT_KEY)) {
        result.aws_commands = true;
    }
    if (hasNonEmptyString(root, GCP_AUTH_REFRESH_KEY)) result.gcp_commands = true;
    if (hasNonEmptyString(root, OTEL_HEADERS_HELPER_KEY)) result.otel_headers_helper = true;
}

fn hasNonEmptyString(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .string => |s| s.len > 0,
        else => false,
    };
}

const testing = std.testing;

fn writeWorkspaceFile(tmp: *std.testing.TmpDir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |dir| {
        tmp.dir.createDirPath(rt.io, dir) catch {};
    }
    try tmp.dir.writeFile(rt.io, .{ .sub_path = rel, .data = body });
}

test "detect enumerates mcp server, hook, and dangerous env var" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeWorkspaceFile(&tmp, ".mcp.json",
        \\{ "mcpServers": { "fetcher": { "command": "node", "args": ["server.js"] } } }
    );
    try writeWorkspaceFile(&tmp, ".claude/settings.json",
        \\{ "hooks": { "PreToolUse": [ { "matcher": "Bash(*)", "hooks": [ { "type": "command", "command": "./pre.sh" } ] } ] } }
    );

    const env = [_]EnvVar{
        .{ .name = "HTTP_PROXY", .value = "http://10.0.0.1:8080" },
    };

    var caps = try detect(allocator, cwd, &env);
    defer caps.deinit();

    try testing.expect(caps.anyDetected());

    try testing.expectEqual(@as(usize, 1), caps.mcp_servers.len);
    try testing.expectEqualStrings("fetcher", caps.mcp_servers[0]);

    try testing.expectEqual(@as(usize, 1), caps.hooks.len);
    try testing.expectEqualStrings("PreToolUse", caps.hooks[0]);

    try testing.expectEqual(@as(usize, 1), caps.dangerous_env_vars.len);
    try testing.expectEqualStrings("HTTP_PROXY", caps.dangerous_env_vars[0]);
}

test "detect on a clean workspace reports anyDetected == false" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    // No .mcp.json, no .claude/settings.json, and only a SAFE env var.
    const env = [_]EnvVar{
        .{ .name = "ANTHROPIC_MODEL", .value = "claude-x" },
    };

    var caps = try detect(allocator, cwd, &env);
    defer caps.deinit();

    try testing.expect(!caps.anyDetected());
    try testing.expectEqual(@as(usize, 0), caps.mcp_servers.len);
    try testing.expectEqual(@as(usize, 0), caps.hooks.len);
    try testing.expectEqual(@as(usize, 0), caps.dangerous_env_vars.len);
}

test "formatBodyLines lists names but never secret values" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeWorkspaceFile(&tmp, ".mcp.json",
        \\{ "mcpServers": { "fetcher": { "command": "node" } } }
    );

    const secret_value = "super-secret-token-9999";
    const env = [_]EnvVar{
        .{ .name = "HTTP_PROXY", .value = secret_value },
    };

    var caps = try detect(allocator, cwd, &env);
    defer caps.deinit();

    const lines = try caps.formatBodyLines(allocator);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    var saw_proxy_name = false;
    var saw_server_name = false;
    for (lines) |l| {
        // The secret VALUE must never leak into the displayed body.
        try testing.expect(std.mem.indexOf(u8, l, secret_value) == null);
        try testing.expect(std.mem.indexOf(u8, l, "9999") == null);
        if (std.mem.indexOf(u8, l, "HTTP_PROXY") != null) saw_proxy_name = true;
        if (std.mem.indexOf(u8, l, "fetcher") != null) saw_server_name = true;
    }
    try testing.expect(saw_proxy_name);
    try testing.expect(saw_server_name);
}

test "detect flags an apiKeyHelper command helper key" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeWorkspaceFile(&tmp, ".claude/settings.json",
        \\{ "apiKeyHelper": "/usr/local/bin/get-key.sh" }
    );

    const env = [_]EnvVar{};
    var caps = try detect(allocator, cwd, &env);
    defer caps.deinit();

    try testing.expect(caps.has_api_key_helper);
    try testing.expect(caps.anyDetected());

    // The helper command path is never echoed in the body (name only).
    const lines = try caps.formatBodyLines(allocator);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }
    var saw_helper = false;
    for (lines) |l| {
        try testing.expect(std.mem.indexOf(u8, l, "get-key.sh") == null);
        if (std.mem.indexOf(u8, l, "API key helper") != null) saw_helper = true;
    }
    try testing.expect(saw_helper);
}

test "detect de-dups multiple hooks on the same event" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    try writeWorkspaceFile(&tmp, ".claude/settings.json",
        \\{ "hooks": { "PreToolUse": [
        \\  { "matcher": "Bash(*)", "hooks": [ { "type": "command", "command": "./a.sh" } ] },
        \\  { "matcher": "Edit(*)", "hooks": [ { "type": "command", "command": "./b.sh" } ] }
        \\] } }
    );

    const env = [_]EnvVar{};
    var caps = try detect(allocator, cwd, &env);
    defer caps.deinit();

    try testing.expectEqual(@as(usize, 1), caps.hooks.len);
    try testing.expectEqualStrings("PreToolUse", caps.hooks[0]);
}
