const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const config_parse = @import("config_parse.zig");
const file_integrity = @import("file_integrity.zig");
const jwks_cache = @import("jwks_cache.zig");
const keychain = @import("keychain.zig");
const paths = @import("paths.zig");
const sandbox = @import("sandbox.zig");

const Status = enum {
    pass,
    warn,
    fail,

    fn label(self: Status) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .warn => "WARN",
            .fail => "FAIL",
        };
    }

    fn json(self: Status) []const u8 {
        return switch (self) {
            .pass => "pass",
            .warn => "warn",
            .fail => "fail",
        };
    }
};

const Check = struct {
    id: []const u8,
    status: Status,
    message: []u8,

    fn deinit(self: *Check, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    json: bool,
    writer: anytype,
) !bool {
    var checks = std.array_list.Managed(Check).init(allocator);
    defer {
        for (checks.items) |*check| check.deinit(allocator);
        checks.deinit();
    }

    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    try checkPlatform(allocator, &checks);
    try checkManagedConfig(allocator, cfg, &checks);
    try checkApprovalPolicy(allocator, cfg, &checks);
    try checkApiAuth(allocator, cfg, &checks);
    try checkSandbox(allocator, cfg, &checks);
    try checkEgress(allocator, cfg, &checks);
    try checkPrivacyPosture(allocator, cfg, &checks);
    try checkTelemetry(allocator, cfg, &checks);
    try checkAudit(allocator, cfg, &resolved, &checks);
    try checkUpdatePolicy(allocator, cfg, &checks);
    try checkKeychain(allocator, &checks);
    try checkPolicyBundle(allocator, &resolved, &checks);
    try checkFleetRelease(allocator, cwd, &checks);
    try checkVsCodeExtension(allocator, cwd, &checks);

    var pass_count: usize = 0;
    var warn_count: usize = 0;
    var fail_count: usize = 0;
    for (checks.items) |check| switch (check.status) {
        .pass => pass_count += 1,
        .warn => warn_count += 1,
        .fail => fail_count += 1,
    };

    if (json) {
        try writeJson(writer, checks.items, pass_count, warn_count, fail_count);
    } else {
        try writer.writeAll("zcode enterprise doctor\n\n");
        for (checks.items) |check| {
            try writer.print("{s} {s}: {s}\n", .{ check.status.label(), check.id, check.message });
        }
        try writer.print("\nSummary: {d} pass, {d} warn, {d} fail\n", .{ pass_count, warn_count, fail_count });
    }

    return fail_count == 0;
}

fn checkPlatform(allocator: std.mem.Allocator, checks: *std.array_list.Managed(Check)) !void {
    switch (builtin.os.tag) {
        .macos, .linux => try add(checks, allocator, "platform", .pass, "supported enterprise platform ({s})", .{@tagName(builtin.os.tag)}),
        else => try add(checks, allocator, "platform", .fail, "unsupported platform for enterprise hardening ({s}); zcode supports macOS and Linux", .{@tagName(builtin.os.tag)}),
    }
}

fn checkManagedConfig(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    const managed_path_opt = try config_parse.resolveManagedConfigPath(allocator);
    const managed_path = managed_path_opt orelse {
        try add(checks, allocator, "managed_config", .warn, "no managed config path for this platform", .{});
        return;
    };
    defer allocator.free(managed_path);

    const dropin_dir = try config_parse.resolveManagedDropInDirPath(allocator, managed_path);
    defer allocator.free(dropin_dir);

    if (pathExists(dropin_dir)) {
        try checkDirectoryPermissions(allocator, checks, "managed_dropin_dir_permissions", dropin_dir, "managed drop-in directory");
    }

    var dropins = config_parse.listManagedDropInFiles(allocator, managed_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => std.array_list.Managed([]u8).init(allocator),
        else => return err,
    };
    defer config_parse.deinitManagedDropInFiles(allocator, &dropins);

    const base_exists = pathExists(managed_path);
    if (!base_exists and dropins.items.len == 0) {
        try add(checks, allocator, "managed_config", .warn, "managed config not deployed at {s} or {s}", .{ managed_path, dropin_dir });
        return;
    }

    if (base_exists) {
        try checkConfigFilePermissions(allocator, checks, "managed_config_permissions", managed_path, "managed config");
        try checkSha256SidecarPermissions(allocator, checks, "managed_config_hash_permissions", managed_path, "managed config SHA-256 sidecar");
        const sidecar_status = file_integrity.verifySha256Sidecar(allocator, managed_path) catch |err| {
            try add(checks, allocator, "managed_config_hash", .fail, "managed config sidecar verification failed: {s}", .{@errorName(err)});
            return;
        };
        try add(checks, allocator, "managed_config_hash", if (sidecar_status == .verified) .pass else .warn, "managed config SHA-256 sidecar is {s}", .{if (sidecar_status == .verified) "verified" else "missing"});
    } else {
        try add(checks, allocator, "managed_config_hash", .warn, "managed base file is missing; using drop-ins from {s}", .{dropin_dir});
    }

    if (dropins.items.len > 0) {
        try add(checks, allocator, "managed_dropins", .pass, "{d} managed drop-in file(s) loaded from {s}", .{ dropins.items.len, dropin_dir });
        var verified: usize = 0;
        for (dropins.items) |dropin_path| {
            try checkConfigFilePermissions(allocator, checks, "managed_dropin_permissions", dropin_path, "managed drop-in");
            try checkSha256SidecarPermissions(allocator, checks, "managed_dropin_hash_permissions", dropin_path, "managed drop-in SHA-256 sidecar");
            const sidecar_status = file_integrity.verifySha256Sidecar(allocator, dropin_path) catch |err| {
                try add(checks, allocator, "managed_dropin_hash", .fail, "managed drop-in sidecar verification failed for {s}: {s}", .{ dropin_path, @errorName(err) });
                return;
            };
            if (sidecar_status == .verified) verified += 1;
        }
        try add(checks, allocator, "managed_dropin_hash", if (verified == dropins.items.len) .pass else .warn, "{d}/{d} managed drop-in SHA-256 sidecars verified", .{ verified, dropins.items.len });
    } else {
        try add(checks, allocator, "managed_dropins", .warn, "no managed drop-ins found at {s}", .{dropin_dir});
    }

    if (cfg.managed_config_sources.len > 0) {
        try add(checks, allocator, "managed_sources", .pass, "loaded managed sources: {s}", .{cfg.managed_config_sources});
    } else {
        try add(checks, allocator, "managed_sources", .warn, "managed path exists but no managed source was applied", .{});
    }

    if (cfg.managed_locked_keys.len > 0) {
        try add(checks, allocator, "managed_locks", .pass, "managed config locks: {s}", .{cfg.managed_locked_keys});
        try checkManagedCriticalLocks(allocator, cfg, checks);
    } else {
        try add(checks, allocator, "managed_locks", .warn, "managed config exists but does not set lockable enterprise keys", .{});
    }
}

fn checkManagedCriticalLocks(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    const critical = [_][]const u8{
        "approval_mode",
        "sandbox",
        "egress_allowlist",
        "egress_allow_private_network_plaintext",
        "privacy_redact_prompt_bodies",
        "session_encryption_enabled",
        "session_retention_days",
        "audit_retention_days",
        "update_require_signature",
        "update_pinned_version",
        "cloud_telemetry_opt_in",
    };

    var missing = std_io.StringBuilder.init(allocator);
    defer missing.deinit();
    for (critical) |key| {
        if (cfg.isManagedLocked(key)) continue;
        if (missing.items().len > 0) try missing.append(',');
        try missing.appendSlice(key);
    }

    if (missing.items().len == 0) {
        try add(checks, allocator, "managed_critical_locks", .pass, "all critical enterprise controls are managed-locked", .{});
    } else {
        try add(checks, allocator, "managed_critical_locks", .warn, "critical enterprise controls not managed-locked: {s}", .{missing.items()});
    }
}

fn checkApprovalPolicy(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (std.mem.eql(u8, cfg.approval_mode, "strict")) {
        try add(checks, allocator, "approval_mode", .pass, "approval_mode=strict is locked down for enterprise review", .{});
    } else {
        try add(checks, allocator, "approval_mode", .warn, "approval_mode={s}; enterprise fleets should lock approval_mode=strict for high-risk actions", .{cfg.approval_mode});
    }
}

fn checkApiAuth(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    const has_oidc = apiOidcComplete(cfg);
    const has_auth_material = cfg.api_bearer_token.len > 0 or has_oidc;
    const auth_surface_configured = cfg.api_auth_required or
        cfg.api_bearer_token.len > 0 or
        apiOidcAny(cfg) or
        cfg.api_profile.len > 0 or
        cfg.api_role.len > 0;

    if (!auth_surface_configured) {
        try add(checks, allocator, "api_auth", .pass, "default local CLI posture does not require zcode-level authentication; API auth is not configured", .{});
        return;
    }

    if (cfg.api_auth_required and has_auth_material) {
        try add(checks, allocator, "api_auth", .pass, "API auth is required and credentials/OIDC are configured", .{});
    } else if (cfg.api_auth_required) {
        try add(checks, allocator, "api_auth", .fail, "api_auth_required=true but no bearer token or complete OIDC configuration is present", .{});
    } else if (has_auth_material) {
        try add(checks, allocator, "api_auth", .warn, "API auth material is configured but api_auth_required=false; API requests can still be unauthenticated", .{});
    } else {
        try add(checks, allocator, "api_auth", .warn, "API profile/role is configured without api_auth_required=true; local CLI posture is fine, but API deployments should require auth", .{});
    }

    if (!has_oidc) {
        try add(checks, allocator, "api_oidc", .warn, "OIDC is not configured; bearer-only auth is harder to govern centrally", .{});
        return;
    }

    if (cfg.api_oidc_jwks_json.len > 0) {
        const n = jwks_cache.countKeys(allocator, cfg.api_oidc_jwks_json) catch |err| {
            try add(checks, allocator, "api_oidc_jwks", .fail, "inline JWKS is invalid: {s}", .{@errorName(err)});
            return;
        };
        try add(checks, allocator, "api_oidc_jwks", .pass, "inline RS256 JWKS has {d} keys", .{n});
    } else if (cfg.api_oidc_jwks_file.len > 0) {
        _ = jwks_cache.sourceFileTrusted(cfg.api_oidc_jwks_file) catch |err| {
            try add(checks, allocator, "api_oidc_jwks_file_permissions", .fail, "JWKS file is not trusted at {s}: {s}", .{ cfg.api_oidc_jwks_file, @errorName(err) });
            return;
        };
        const raw = std.Io.Dir.cwd().readFileAlloc(rt.io, cfg.api_oidc_jwks_file, allocator, .limited(jwks_cache.max_jwks_bytes)) catch |err| {
            try add(checks, allocator, "api_oidc_jwks", .fail, "JWKS file is unreadable: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(raw);
        const n = jwks_cache.countKeys(allocator, raw) catch |err| {
            try add(checks, allocator, "api_oidc_jwks", .fail, "JWKS file is invalid: {s}", .{@errorName(err)});
            return;
        };
        try add(checks, allocator, "api_oidc_jwks", .pass, "JWKS file has {d} keys", .{n});
    } else if (cfg.api_oidc_jwks_url.len > 0) {
        const cache_path = try jwks_cache.cacheFilePath(allocator);
        defer allocator.free(cache_path);
        if (pathExists(cache_path)) {
            _ = jwks_cache.cacheFileTrusted(cache_path) catch |err| {
                try add(checks, allocator, "api_oidc_jwks_cache_permissions", .fail, "JWKS cache is not trusted at {s}: {s}", .{ cache_path, @errorName(err) });
                return;
            };
            const has_meta = jwks_cache.cacheMetadataTrusted(allocator, cache_path) catch |err| {
                try add(checks, allocator, "api_oidc_jwks_cache_meta_permissions", .fail, "JWKS cache metadata is not trusted for {s}: {s}", .{ cache_path, @errorName(err) });
                return;
            };
            if (!has_meta) {
                try add(checks, allocator, "api_oidc_jwks_cache_meta", .warn, "JWKS URL cache exists but freshness metadata is missing", .{});
                return;
            }
            try add(checks, allocator, "api_oidc_jwks", .pass, "JWKS URL configured and cache exists", .{});
        } else {
            try add(checks, allocator, "api_oidc_jwks", .warn, "JWKS URL configured; cache is not populated yet", .{});
        }
    } else {
        try add(checks, allocator, "api_oidc_jwks", .pass, "OIDC uses HS256 shared-secret validation", .{});
    }
}

fn apiOidcAny(cfg: *const config_mod.Config) bool {
    return cfg.api_oidc_issuer.len > 0 or
        cfg.api_oidc_audience.len > 0 or
        cfg.api_oidc_hs256_secret.len > 0 or
        cfg.api_oidc_jwks_json.len > 0 or
        cfg.api_oidc_jwks_file.len > 0 or
        cfg.api_oidc_jwks_url.len > 0;
}

fn apiOidcComplete(cfg: *const config_mod.Config) bool {
    return cfg.api_oidc_issuer.len > 0 and
        cfg.api_oidc_audience.len > 0 and
        (cfg.api_oidc_hs256_secret.len > 0 or
            cfg.api_oidc_jwks_json.len > 0 or
            cfg.api_oidc_jwks_file.len > 0 or
            cfg.api_oidc_jwks_url.len > 0);
}

fn checkSandbox(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (std.mem.eql(u8, cfg.sandbox, "danger-full-access") or std.mem.eql(u8, cfg.sandbox, "none")) {
        try add(checks, allocator, "sandbox", .warn, "sandbox profile '{s}' bypasses isolation; enterprise fleets should use workspace-write, read-only, or no-network", .{cfg.sandbox});
        return;
    }

    if (sandbox.hasShellSandboxBackend(cfg.sandbox)) {
        try add(checks, allocator, "sandbox", .pass, "sandbox profile '{s}' has an enforced shell isolation backend", .{cfg.sandbox});
    } else if (sandbox.requiresEnforcedShellSandbox(cfg.sandbox)) {
        try add(checks, allocator, "sandbox", .fail, "sandbox profile '{s}' requires sandbox-exec/bwrap but no backend was found", .{cfg.sandbox});
    } else {
        try add(checks, allocator, "sandbox", .warn, "sandbox profile '{s}' is not enforced", .{cfg.sandbox});
    }
}

fn checkEgress(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (cfg.egress_allowlist.len > 0) {
        try add(checks, allocator, "egress", .pass, "egress allowlist configured: {s}", .{cfg.egress_allowlist});
    } else {
        try add(checks, allocator, "egress", .warn, "egress allowlist is empty; providers can reach any HTTPS host allowed by SSRF policy", .{});
    }
}

fn checkPrivacyPosture(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (cfg.session_encryption_enabled) {
        try add(checks, allocator, "session_encryption", .pass, "session-at-rest encryption is enabled", .{});
    } else {
        try add(checks, allocator, "session_encryption", .warn, "session_encryption_enabled=false; enterprise fleets should encrypt session records at rest", .{});
    }

    if (cfg.privacy_redact_prompt_bodies) {
        try add(checks, allocator, "privacy_redaction", .pass, "prompt/response bodies are redacted from audit and telemetry payloads", .{});
    } else {
        try add(checks, allocator, "privacy_redaction", .warn, "privacy_redact_prompt_bodies=false; enterprise fleets should avoid storing prompt bodies in logs", .{});
    }
}

fn checkTelemetry(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (!cfg.cloud_telemetry_opt_in) {
        try add(checks, allocator, "telemetry", .pass, "cloud telemetry uploads are disabled", .{});
        return;
    }

    if (cfg.control_plane_url.len == 0) {
        try add(checks, allocator, "telemetry", .warn, "cloud_telemetry_opt_in=true but control_plane_url is empty; audit evidence remains local only", .{});
        return;
    }

    if (!controlPlaneTransportAllowed(cfg.control_plane_url)) {
        try add(checks, allocator, "telemetry", .fail, "cloud telemetry control_plane_url must use https:// or loopback http://, got {s}", .{cfg.control_plane_url});
        return;
    }

    try add(checks, allocator, "telemetry", .pass, "cloud telemetry uploads use approved control-plane transport: {s}", .{cfg.control_plane_url});
}

fn controlPlaneTransportAllowed(url: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(url, "https://")) {
        return controlPlaneHost(url["https://".len..]) != null;
    }
    if (!std.ascii.startsWithIgnoreCase(url, "http://")) return false;
    const host = controlPlaneHost(url["http://".len..]) orelse return false;
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "[::1]");
}

fn controlPlaneHost(rest: []const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    if (rest[0] == '[') {
        const end = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
        if (end == 1) return null;
        if (end + 1 < rest.len) {
            const next = rest[end + 1];
            if (next != ':' and next != '/' and next != '?' and next != '#') return null;
        }
        return rest[0 .. end + 1];
    }
    const end = std.mem.indexOfAny(u8, rest, ":/?#") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn checkAudit(allocator: std.mem.Allocator, cfg: *const config_mod.Config, resolved: *const paths.PathSet, checks: *std.array_list.Managed(Check)) !void {
    try checkSessionRetention(allocator, cfg, checks);

    if (cfg.audit_retention_days > 0) {
        try add(checks, allocator, "audit_retention", .pass, "audit retention is {d} days", .{cfg.audit_retention_days});
    } else {
        try add(checks, allocator, "audit_retention", .warn, "audit retention cleanup is disabled", .{});
    }

    const hmac_path = try std.fs.path.join(allocator, &.{ resolved.logs_dir, "hmac.key" });
    defer allocator.free(hmac_path);
    try add(checks, allocator, "audit_hmac", if (pathExists(hmac_path)) .pass else .warn, "audit HMAC key {s}", .{if (pathExists(hmac_path)) "exists" else "has not been created yet"});
    if (pathExists(resolved.logs_dir)) {
        try checkPrivateDirectoryPermissions(allocator, checks, "audit_log_dir_permissions", resolved.logs_dir, "audit log directory");
    }
    if (pathExists(hmac_path)) {
        try checkSecretFilePermissions(allocator, checks, "audit_hmac_permissions", hmac_path, "audit HMAC key");
    }
    if (pathExists(resolved.sessions_dir)) {
        try checkPrivateDirectoryPermissions(allocator, checks, "session_dir_permissions", resolved.sessions_dir, "session directory");
    }
}

fn checkSessionRetention(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (cfg.session_retention_days > 0) {
        try add(checks, allocator, "session_retention", .pass, "session retention is {d} days", .{cfg.session_retention_days});
    } else {
        try add(checks, allocator, "session_retention", .warn, "session retention cleanup is disabled; set session_retention_days for fleet evidence policy", .{});
    }
}

fn checkUpdatePolicy(allocator: std.mem.Allocator, cfg: *const config_mod.Config, checks: *std.array_list.Managed(Check)) !void {
    if (cfg.update_require_signature) {
        try add(checks, allocator, "update_signature", .pass, "release signature verification is required", .{});
    } else {
        try add(checks, allocator, "update_signature", .warn, "update_require_signature=false; enterprise fleets should require signed releases", .{});
    }

    if (cfg.update_pinned_version.len > 0) {
        try add(checks, allocator, "update_pin", .pass, "updates are pinned at {s}", .{cfg.update_pinned_version});
    } else {
        try add(checks, allocator, "update_pin", .warn, "no update_pinned_version set; fleets cannot hold a staged release", .{});
    }
}

fn checkKeychain(allocator: std.mem.Allocator, checks: *std.array_list.Managed(Check)) !void {
    const backend = keychain.Backend.detect();
    if (backend == .file_fallback) {
        try add(checks, allocator, "keychain", .warn, "keychain backend is file_fallback; prefer OS keychain on managed machines", .{});
    } else {
        try add(checks, allocator, "keychain", .pass, "keychain backend is {s}", .{@tagName(backend)});
    }
}

fn checkPolicyBundle(allocator: std.mem.Allocator, resolved: *const paths.PathSet, checks: *std.array_list.Managed(Check)) !void {
    if (std.fs.path.dirname(resolved.policy_path)) |policy_dir| {
        if (pathExists(policy_dir)) {
            try checkDirectoryPermissions(allocator, checks, "policy_dir_permissions", policy_dir, "policy directory");
        }
    }
    if (pathExists(resolved.policy_path)) {
        try checkConfigFilePermissions(allocator, checks, "policy_permissions", resolved.policy_path, "policy file");
        try checkSha256SidecarPermissions(allocator, checks, "policy_hash_permissions", resolved.policy_path, "policy SHA-256 sidecar");
    }
    const sidecar_status = file_integrity.verifySha256Sidecar(allocator, resolved.policy_path) catch |err| {
        if (err == error.FileNotFound) {
            try add(checks, allocator, "policy_hash", .warn, "policy file is not deployed yet", .{});
            return;
        }
        try add(checks, allocator, "policy_hash", .fail, "policy sidecar verification failed: {s}", .{@errorName(err)});
        return;
    };
    try add(checks, allocator, "policy_hash", if (sidecar_status == .verified) .pass else .warn, "policy SHA-256 sidecar is {s}", .{if (sidecar_status == .verified) "verified" else "missing"});
}

fn checkSha256SidecarPermissions(
    allocator: std.mem.Allocator,
    checks: *std.array_list.Managed(Check),
    id: []const u8,
    target_path: []const u8,
    label: []const u8,
) !void {
    const sidecar_path = try file_integrity.sidecarPath(allocator, target_path);
    defer allocator.free(sidecar_path);
    if (!pathExists(sidecar_path)) return;
    try checkConfigFilePermissions(allocator, checks, id, sidecar_path, label);
}

fn checkFleetRelease(allocator: std.mem.Allocator, cwd: []const u8, checks: *std.array_list.Managed(Check)) !void {
    const release_workflow = try std.fs.path.join(allocator, &.{ cwd, ".github", "workflows", "release.yml" });
    defer allocator.free(release_workflow);
    const audit_script = try std.fs.path.join(allocator, &.{ cwd, "scripts", "release", "audit_release_artifacts.sh" });
    defer allocator.free(audit_script);
    if (pathExists(release_workflow) and pathExists(audit_script)) {
        try add(checks, allocator, "fleet_release", .pass, "release workflow and artifact-audit script are present", .{});
    } else {
        try add(checks, allocator, "fleet_release", .warn, "release workflow or artifact-audit script is missing from this checkout", .{});
    }
}

fn checkVsCodeExtension(allocator: std.mem.Allocator, cwd: []const u8, checks: *std.array_list.Managed(Check)) !void {
    const package_path = try std.fs.path.join(allocator, &.{ cwd, "extensions", "vscode", "package.json" });
    defer allocator.free(package_path);
    if (pathExists(package_path)) {
        try add(checks, allocator, "vscode_extension", .pass, "VS Code extension manifest is present", .{});
    } else {
        try add(checks, allocator, "vscode_extension", .warn, "VS Code extension manifest is missing from this checkout", .{});
    }
}

fn add(
    checks: *std.array_list.Managed(Check),
    allocator: std.mem.Allocator,
    id: []const u8,
    status: Status,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    try checks.append(.{ .id = id, .status = status, .message = msg });
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

fn checkDirectoryPermissions(
    allocator: std.mem.Allocator,
    checks: *std.array_list.Managed(Check),
    id: []const u8,
    path: []const u8,
    label: []const u8,
) !void {
    const stat = statPath(path) catch |err| {
        try add(checks, allocator, id, .warn, "{s} permissions could not be inspected at {s}: {s}", .{ label, path, @errorName(err) });
        return;
    };
    if (groupOrWorldWritable(stat.permissions.toMode())) {
        try add(checks, allocator, id, .fail, "{s} is group/world writable at {s} (mode 0o{o:0>3}); lock it to owner/admin writes only", .{ label, path, permissionBits(stat.permissions.toMode()) });
    } else {
        try add(checks, allocator, id, .pass, "{s} is not group/world writable at {s} (mode 0o{o:0>3})", .{ label, path, permissionBits(stat.permissions.toMode()) });
    }
}

fn checkPrivateDirectoryPermissions(
    allocator: std.mem.Allocator,
    checks: *std.array_list.Managed(Check),
    id: []const u8,
    path: []const u8,
    label: []const u8,
) !void {
    const stat = statPath(path) catch |err| {
        try add(checks, allocator, id, .warn, "{s} permissions could not be inspected at {s}: {s}", .{ label, path, @errorName(err) });
        return;
    };
    if (groupOrWorldWritable(stat.permissions.toMode())) {
        try add(checks, allocator, id, .fail, "{s} is group/world writable at {s} (mode 0o{o:0>3}); lock it to owner/admin writes only", .{ label, path, permissionBits(stat.permissions.toMode()) });
    } else if (groupOrWorldAny(stat.permissions.toMode())) {
        try add(checks, allocator, id, .warn, "{s} is readable/searchable by group/world at {s} (mode 0o{o:0>3}); prefer owner-only 0700 for enterprise confidentiality", .{ label, path, permissionBits(stat.permissions.toMode()) });
    } else {
        try add(checks, allocator, id, .pass, "{s} is owner-only at {s} (mode 0o{o:0>3})", .{ label, path, permissionBits(stat.permissions.toMode()) });
    }
}

fn checkConfigFilePermissions(
    allocator: std.mem.Allocator,
    checks: *std.array_list.Managed(Check),
    id: []const u8,
    path: []const u8,
    label: []const u8,
) !void {
    const stat = statPath(path) catch |err| {
        try add(checks, allocator, id, .warn, "{s} permissions could not be inspected at {s}: {s}", .{ label, path, @errorName(err) });
        return;
    };
    if (groupOrWorldWritable(stat.permissions.toMode())) {
        try add(checks, allocator, id, .fail, "{s} is group/world writable at {s} (mode 0o{o:0>3}); managed policy can be bypassed by local writes", .{ label, path, permissionBits(stat.permissions.toMode()) });
        return;
    }
    if (worldReadable(stat.permissions.toMode()) and fileContainsSensitiveConfigKey(allocator, path)) {
        try add(checks, allocator, id, .warn, "{s} contains sensitive keys and is world-readable at {s} (mode 0o{o:0>3}); prefer 0640/0600 with an admin group", .{ label, path, permissionBits(stat.permissions.toMode()) });
        return;
    }
    try add(checks, allocator, id, .pass, "{s} permissions are acceptable at {s} (mode 0o{o:0>3})", .{ label, path, permissionBits(stat.permissions.toMode()) });
}

fn checkSecretFilePermissions(
    allocator: std.mem.Allocator,
    checks: *std.array_list.Managed(Check),
    id: []const u8,
    path: []const u8,
    label: []const u8,
) !void {
    const stat = statPath(path) catch |err| {
        try add(checks, allocator, id, .warn, "{s} permissions could not be inspected at {s}: {s}", .{ label, path, @errorName(err) });
        return;
    };
    if (groupOrWorldAny(stat.permissions.toMode())) {
        try add(checks, allocator, id, .fail, "{s} is readable/writable by group/world at {s} (mode 0o{o:0>3}); expected owner-only 0600", .{ label, path, permissionBits(stat.permissions.toMode()) });
    } else {
        try add(checks, allocator, id, .pass, "{s} is owner-only at {s} (mode 0o{o:0>3})", .{ label, path, permissionBits(stat.permissions.toMode()) });
    }
}

fn statPath(path: []const u8) !std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(rt.io, path, .{});
}

fn groupOrWorldWritable(mode: std.posix.mode_t) bool {
    return (mode & 0o022) != 0;
}

fn groupOrWorldAny(mode: std.posix.mode_t) bool {
    return (mode & 0o077) != 0;
}

fn worldReadable(mode: std.posix.mode_t) bool {
    return (mode & 0o004) != 0;
}

fn permissionBits(mode: std.posix.mode_t) std.posix.mode_t {
    return mode & 0o777;
}

fn fileContainsSensitiveConfigKey(allocator: std.mem.Allocator, path: []const u8) bool {
    const body = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(body);

    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        const key = configKeyFromLine(line) orelse continue;
        if (isSensitiveConfigKey(key)) return true;
    }
    return false;
}

fn configKeyFromLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, "#")) return null;
    if (std.mem.startsWith(u8, line, "[")) return null;
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return std.mem.trim(u8, line[0..eq_idx], " \t");
}

fn isSensitiveConfigKey(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "api_key") != null or
        std.mem.indexOf(u8, key, "token") != null or
        std.mem.indexOf(u8, key, "secret") != null or
        std.mem.indexOf(u8, key, "credential") != null or
        std.mem.indexOf(u8, key, "password") != null or
        std.mem.eql(u8, key, "api_bearer_token");
}

fn writeJson(writer: anytype, checks: []const Check, pass_count: usize, warn_count: usize, fail_count: usize) !void {
    try writer.print("{{\"ok\":{},\"summary\":{{\"pass\":{d},\"warn\":{d},\"fail\":{d}}},\"checks\":[", .{ fail_count == 0, pass_count, warn_count, fail_count });
    for (checks, 0..) |check, idx| {
        if (idx > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":\"{s}\",\"status\":\"{s}\",\"message\":", .{ check.id, check.status.json() });
        try writeJsonString(writer, check.message);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

test "enterprise permission helpers classify unsafe modes" {
    try testing.expect(!groupOrWorldWritable(0o644));
    try testing.expect(groupOrWorldWritable(0o664));
    try testing.expect(groupOrWorldWritable(0o606));
    try testing.expect(!groupOrWorldAny(0o600));
    try testing.expect(groupOrWorldAny(0o640));
    try testing.expect(worldReadable(0o604));
}

test "enterprise sensitive config key detection" {
    try testing.expect(isSensitiveConfigKey("api_bearer_token"));
    try testing.expect(isSensitiveConfigKey("control_plane_token"));
    try testing.expect(isSensitiveConfigKey("provider_api_key"));
    try testing.expect(!isSensitiveConfigKey("api_oidc_jwks_file"));
    try testing.expect(!isSensitiveConfigKey("default_model"));
}

fn deinitChecks(allocator: std.mem.Allocator, checks: *std.array_list.Managed(Check)) void {
    for (checks.items) |*check| check.deinit(allocator);
    checks.deinit();
}

test "enterprise doctor treats API auth as optional for local CLI posture" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    var checks = std.array_list.Managed(Check).init(testing.allocator);
    defer deinitChecks(testing.allocator, &checks);

    try checkApiAuth(testing.allocator, &cfg, &checks);

    try testing.expectEqual(@as(usize, 1), checks.items.len);
    try testing.expectEqual(Status.pass, checks.items[0].status);
    try testing.expectEqualStrings("api_auth", checks.items[0].id);
}

test "enterprise doctor warns when API auth material is configured but not required" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    try cfg.setOwnedString(testing.allocator, &cfg.api_bearer_token, "test-token");

    var checks = std.array_list.Managed(Check).init(testing.allocator);
    defer deinitChecks(testing.allocator, &checks);

    try checkApiAuth(testing.allocator, &cfg, &checks);

    try testing.expectEqual(@as(usize, 2), checks.items.len);
    try testing.expectEqual(Status.warn, checks.items[0].status);
    try testing.expectEqualStrings("api_auth", checks.items[0].id);
    try testing.expectEqual(Status.warn, checks.items[1].status);
    try testing.expectEqualStrings("api_oidc", checks.items[1].id);
}

test "enterprise doctor warns on full sandbox bypass" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    try cfg.setOwnedString(testing.allocator, &cfg.sandbox, "danger-full-access");

    var checks = std.array_list.Managed(Check).init(testing.allocator);
    defer deinitChecks(testing.allocator, &checks);

    try checkSandbox(testing.allocator, &cfg, &checks);

    try testing.expectEqual(@as(usize, 1), checks.items.len);
    try testing.expectEqual(Status.warn, checks.items[0].status);
    try testing.expectEqualStrings("sandbox", checks.items[0].id);
}

test "enterprise doctor warns when approval mode is not strict" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    var checks = std.array_list.Managed(Check).init(testing.allocator);
    defer deinitChecks(testing.allocator, &checks);

    try checkApprovalPolicy(testing.allocator, &cfg, &checks);

    try testing.expectEqual(@as(usize, 1), checks.items.len);
    try testing.expectEqual(Status.warn, checks.items[0].status);
    try testing.expectEqualStrings("approval_mode", checks.items[0].id);
}

test "enterprise doctor passes strict approval mode" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    try cfg.setOwnedString(testing.allocator, &cfg.approval_mode, "strict");

    var checks = std.array_list.Managed(Check).init(testing.allocator);
    defer deinitChecks(testing.allocator, &checks);

    try checkApprovalPolicy(testing.allocator, &cfg, &checks);

    try testing.expectEqual(@as(usize, 1), checks.items.len);
    try testing.expectEqual(Status.pass, checks.items[0].status);
    try testing.expectEqualStrings("approval_mode", checks.items[0].id);
}

test "enterprise doctor checks telemetry transport" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkTelemetry(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.pass, checks.items[0].status);
        try testing.expectEqualStrings("telemetry", checks.items[0].id);
    }

    cfg.cloud_telemetry_opt_in = true;
    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkTelemetry(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.warn, checks.items[0].status);
        try testing.expectEqualStrings("telemetry", checks.items[0].id);
    }

    try cfg.setOwnedString(testing.allocator, &cfg.control_plane_url, "http://zcode.internal.example.com");
    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkTelemetry(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.fail, checks.items[0].status);
        try testing.expectEqualStrings("telemetry", checks.items[0].id);
    }

    try cfg.setOwnedString(testing.allocator, &cfg.control_plane_url, "https://zcode.internal.example.com");
    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkTelemetry(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.pass, checks.items[0].status);
        try testing.expectEqualStrings("telemetry", checks.items[0].id);
    }
}

test "enterprise doctor allows loopback telemetry transport for local collectors" {
    try testing.expect(controlPlaneTransportAllowed("https://zcode.internal.example.com"));
    try testing.expect(controlPlaneTransportAllowed("HTTPS://zcode.internal.example.com/audit"));
    try testing.expect(controlPlaneTransportAllowed("http://localhost:8787"));
    try testing.expect(controlPlaneTransportAllowed("http://127.0.0.1:8787"));
    try testing.expect(controlPlaneTransportAllowed("http://[::1]:8787"));
    try testing.expect(!controlPlaneTransportAllowed("https://"));
    try testing.expect(!controlPlaneTransportAllowed("http://zcode.internal.example.com"));
    try testing.expect(!controlPlaneTransportAllowed("http://localhost.evil.example.com"));
    try testing.expect(!controlPlaneTransportAllowed("http://[::1].evil.example.com"));
}

test "enterprise doctor checks session retention policy" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkSessionRetention(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.warn, checks.items[0].status);
        try testing.expectEqualStrings("session_retention", checks.items[0].id);
    }

    cfg.session_retention_days = 180;
    {
        var checks = std.array_list.Managed(Check).init(testing.allocator);
        defer deinitChecks(testing.allocator, &checks);

        try checkSessionRetention(testing.allocator, &cfg, &checks);

        try testing.expectEqual(@as(usize, 1), checks.items.len);
        try testing.expectEqual(Status.pass, checks.items[0].status);
        try testing.expectEqualStrings("session_retention", checks.items[0].id);
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

const testing = std.testing;

test "enterprise doctor json string escapes control bytes" {
    var out = std_io.StringBuilder.init(testing.allocator);
    defer out.deinit();
    try writeJsonString(out.writer(), "a\"b\\c\n");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items());
}
