const std = @import("std");
const rt = @import("zcode_runtime");
const clock = @import("clock.zig");
const std_io = @import("std_io.zig");
const cli = @import("../cli/args.zig");
const paths = @import("paths.zig");
const config_mod = @import("config.zig");
const file_integrity = @import("file_integrity.zig");
const managed_security = @import("managed_security.zig");

const Config = config_mod.Config;
const LoadedConfig = config_mod.LoadedConfig;

pub fn load(allocator: std.mem.Allocator, cwd: []const u8, opts: *const cli.CliOptions) !LoadedConfig {
    var cfg = try Config.init(allocator);
    errdefer cfg.deinit(allocator);

    var resolved_paths = try paths.resolve(allocator);
    errdefer resolved_paths.deinit(allocator);

    const ws_cfg_path = try paths.workspaceConfigPath(allocator, cwd);
    errdefer allocator.free(ws_cfg_path);

    // settings-05: `--setting-sources user,project,local` gates the three
    // non-forced layers. When the flag is absent (opts.setting_sources ==
    // null) every layer loads, byte-identical to the legacy behavior. The
    // managed (policy) block and CLI overrides (flag) below are always
    // forced on, matching the reference getEnabledSettingSources.
    const load_user = if (opts.setting_sources) |s| s.user else true;
    const load_workspace = if (opts.setting_sources) |s| s.project else true;
    const load_local = if (opts.setting_sources) |s| s.local else true;

    const user_found = if (load_user) (mergeFromFile(allocator, &cfg, resolved_paths.user_config_path) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    }) else false;

    const workspace_found = if (load_workspace) (mergeFromFile(allocator, &cfg, ws_cfg_path) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    }) else false;

    // Local config layer (git-ignored, for per-machine overrides)
    const local_cfg_path = try paths.workspacePathAlloc(allocator, cwd, "settings.local.toml");
    defer allocator.free(local_cfg_path);
    if (load_local) {
        _ = mergeFromFile(allocator, &cfg, local_cfg_path) catch |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
    }

    try applyCliOverrides(allocator, &cfg, opts);
    applyTelemetryEnvOverride(&cfg);

    // Managed config (E18): a system-level file that an admin can
    // push via MDM / Jamf / Ansible. Applied LAST so it
    // overrides user config, workspace config, local settings, and
    // CLI flags. Fleet operators get the final word on locked keys.
    var managed_dangerous: ?managed_security.DangerousSummary = null;
    errdefer if (managed_dangerous) |*d| d.deinit();
    const managed_path = resolveManagedConfigPath(allocator) catch null;
    if (managed_path) |p| {
        defer allocator.free(p);
        if (cfg.control_plane_managed_settings_sync and cfg.control_plane_url.len > 0) {
            const control_plane = @import("control_plane.zig");
            _ = control_plane.syncManagedSettings(
                allocator,
                cfg.control_plane_url,
                cfg.control_plane_token,
                p,
                cfg.control_plane_managed_settings_verify_hash,
            ) catch |err| blk: {
                std_io.stderrWriter().print(
                    "zcode: warning: managed settings sync failed: {s}. Using cached/local managed config if present.\n",
                    .{@errorName(err)},
                ) catch {};
                break :blk false;
            };
        }
        managed_dangerous = mergeManagedConfigSet(allocator, &cfg, p) catch |err| switch (err) {
            // File absent = no managed policy deployed; the normal
            // case on developer workstations.
            error.FileNotFound => null,
            // File present but unreadable = a managed policy IS
            // deployed and we cannot apply it. Falling back to the
            // user's config here would defeat the lockdown, so fail
            // closed. A 0640 root:admin deployment (the shape the
            // Jamf/Ansible playbooks encourage) should NOT
            // bypass policy for ordinary users.
            else => return err,
        };
    }

    @import("feature_gates.zig").applyKillSwitches(&cfg);

    return .{
        .config = cfg,
        .paths = resolved_paths,
        .workspace_config_path = ws_cfg_path,
        .user_config_found = user_found,
        .workspace_config_found = workspace_found,
        .managed_dangerous = managed_dangerous,
    };
}

fn applyTelemetryEnvOverride(cfg: *Config) void {
    // Env overrides remain useful for unmanaged workstations, but they
    // are applied before managed config so fleet policy is authoritative.
    if (@import("env.zig").getenv("ZCODE_TELEMETRY")) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "0") or std.ascii.eqlIgnoreCase(v, "no")) {
            cfg.cloud_telemetry_opt_in = false;
        } else if (std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "1") or std.ascii.eqlIgnoreCase(v, "yes")) {
            cfg.cloud_telemetry_opt_in = true;
        } else if (v.len > 0) {
            std_io.stderrWriter().print(
                "zcode: warning: ignoring unknown ZCODE_TELEMETRY value '{s}'. Expected off|on.\n",
                .{v},
            ) catch {};
        }
    }
}

/// Resolve the path to the system-level managed config. Order:
///   1. ZCODE_MANAGED_CONFIG env var (for CI and testing)
///   2. Platform default:
///      - Linux:   /etc/zcode/managed.toml
///      - macOS:   /Library/Application Support/zcode/managed.toml
pub fn resolveManagedConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    if (@import("env.zig").getenv("ZCODE_MANAGED_CONFIG")) |p| {
        const trimmed = std.mem.trim(u8, p, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    const builtin_os = @import("builtin").os.tag;
    return switch (builtin_os) {
        .linux => try allocator.dupe(u8, "/etc/zcode/managed.toml"),
        .macos => try allocator.dupe(u8, "/Library/Application Support/zcode/managed.toml"),
        else => null,
    };
}

pub fn resolveManagedDropInDirPath(allocator: std.mem.Allocator, managed_config_path: []const u8) ![]u8 {
    const base_dir = std.fs.path.dirname(managed_config_path) orelse ".";
    return std.fs.path.join(allocator, &.{ base_dir, "managed.d" });
}

pub fn listManagedDropInFiles(allocator: std.mem.Allocator, managed_config_path: []const u8) !std.array_list.Managed([]u8) {
    const dropin_dir = try resolveManagedDropInDirPath(allocator, managed_config_path);
    defer allocator.free(dropin_dir);
    return listManagedDropInFilesInDir(allocator, dropin_dir);
}

pub fn deinitManagedDropInFiles(allocator: std.mem.Allocator, files: *std.array_list.Managed([]u8)) void {
    for (files.items) |path| allocator.free(path);
    files.deinit();
}

fn mergeFromFile(allocator: std.mem.Allocator, cfg: *Config, path: []const u8) !bool {
    const file_data = try readConfigFile(allocator, path);
    defer allocator.free(file_data);

    try mergeConfigBody(allocator, cfg, file_data);
    return true;
}

/// Merge the managed base file plus its managed.d drop-ins. Returns the
/// collected DangerousSummary (settings-03) when at least one managed file was
/// applied, or null when none was found. The caller owns the summary and frees
/// it via LoadedConfig.deinit.
fn mergeManagedConfigSet(allocator: std.mem.Allocator, cfg: *Config, path: []const u8) !?managed_security.DangerousSummary {
    var locked_keys = std_io.StringBuilder.init(allocator);
    errdefer locked_keys.deinit();
    var sources = std_io.StringBuilder.init(allocator);
    errdefer sources.deinit();
    // Accumulate dangerous keys across the base file + every drop-in so the
    // approval gate sees the full picture of what is about to be applied.
    var dangerous = managed_security.DangerousSummary.init(allocator);
    errdefer dangerous.deinit();

    var found = false;
    const base_loaded = mergeManagedFileInto(allocator, cfg, path, &locked_keys, &sources, &dangerous) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    found = found or base_loaded;

    var dropins = listManagedDropInFiles(allocator, path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => std.array_list.Managed([]u8).init(allocator),
        else => return err,
    };
    defer deinitManagedDropInFiles(allocator, &dropins);

    for (dropins.items) |dropin_path| {
        _ = try mergeManagedFileInto(allocator, cfg, dropin_path, &locked_keys, &sources, &dangerous);
        found = true;
    }

    if (!found) {
        locked_keys.deinit();
        sources.deinit();
        dangerous.deinit();
        return null;
    }

    allocator.free(cfg.managed_locked_keys);
    cfg.managed_locked_keys = try locked_keys.toOwnedSlice();
    allocator.free(cfg.managed_config_sources);
    cfg.managed_config_sources = try sources.toOwnedSlice();
    return dangerous;
}

fn mergeManagedFileInto(
    allocator: std.mem.Allocator,
    cfg: *Config,
    path: []const u8,
    locked_keys: *std_io.StringBuilder,
    sources: *std_io.StringBuilder,
    dangerous: *managed_security.DangerousSummary,
) !bool {
    const file_data = try readConfigFile(allocator, path);
    defer allocator.free(file_data);

    _ = try file_integrity.verifySha256SidecarForBytes(allocator, path, file_data);

    const body = stripBom(file_data);
    // Single line scan for both the lockable-key list and the dangerous-key
    // summary (settings-03). Track the current `[section]` so an env key is
    // classified against SAFE_ENV_VARS and a `[hooks]` section is flagged --
    // a scalar key is classified against the command-helper list.
    var current_section: ?[]const u8 = null;
    var collect_it = std.mem.splitScalar(u8, body, '\n');
    while (collect_it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;
        if (std.mem.startsWith(u8, trimmed, "[")) {
            if (std.mem.indexOfScalar(u8, trimmed, ']')) |close_idx| {
                const section = std.mem.trim(u8, trimmed[1..close_idx], " \t");
                current_section = section;
                if (std.mem.eql(u8, section, "hooks")) dangerous.noteHooks();
            } else {
                current_section = null;
            }
            continue;
        }
        const key = configKeyFromLine(trimmed) orelse continue;
        if (isManagedLockableKey(key)) {
            try appendLockedKeyUnique(locked_keys, key);
        }
        if (current_section) |section| {
            if (std.mem.eql(u8, section, "env")) {
                try dangerous.noteEnvKey(key);
                continue;
            }
        }
        try dangerous.noteScalarKey(key);
    }

    try mergeManagedConfigBody(allocator, cfg, file_data, path);
    try appendCsvValueUnique(sources, path);
    return true;
}

fn listManagedDropInFilesInDir(allocator: std.mem.Allocator, dropin_dir: []const u8) !std.array_list.Managed([]u8) {
    var dir = try std.Io.Dir.cwd().openDir(rt.io, dropin_dir, .{ .iterate = true });
    defer dir.close(rt.io);

    var files = std.array_list.Managed([]u8).init(allocator);
    errdefer deinitManagedDropInFiles(allocator, &files);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.') continue;
        if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dropin_dir, entry.name });
        errdefer allocator.free(full_path);
        try files.append(full_path);
    }

    std.mem.sort([]u8, files.items, {}, stringLessThan);
    return files;
}

fn stringLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file_data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1_048_576)) catch |err| switch (err) {
        // A 1MB limit is generous for a key-value config; exceeding
        // it almost always means a stray blob got pasted in. Name
        // the file + limit so the user can fix it without having to
        // guess the boundary.
        error.FileTooBig => {
            std_io.stderrWriter().print(
                "zcode: config error: {s} exceeds the 1 MiB config size limit.\n  - Trim the file, or move large data out of config.toml.\n",
                .{path},
            ) catch {};
            return err;
        },
        else => return err,
    };
    return file_data;
}

fn mergeConfigBody(allocator: std.mem.Allocator, cfg: *Config, file_data: []const u8) !void {
    // Skip a leading UTF-8 BOM (EF BB BF) if present. Windows editors
    // (Notepad, older VS Code defaults, PowerShell Set-Content under
    // some locales) silently prepend it and it used to get merged
    // into the first key name, producing a cryptic
    //   zcode: config warning: unknown key '<BOM>default_model' (ignored)
    // on every startup.
    const body = stripBom(file_data);

    var current_section: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try mergeLineWithMode(allocator, cfg, line, null, false, &current_section);
    }
}

fn mergeManagedConfigBody(allocator: std.mem.Allocator, cfg: *Config, file_data: []const u8, path: []const u8) !void {
    const body = stripBom(file_data);

    var current_section: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try mergeLineWithMode(allocator, cfg, line, path, true, &current_section);
    }
}

fn stripBom(file_data: []const u8) []const u8 {
    return if (file_data.len >= 3 and
        file_data[0] == 0xEF and file_data[1] == 0xBB and file_data[2] == 0xBF)
        file_data[3..]
    else
        file_data;
}

fn configKeyFromLine(raw_line: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return null;
    if (std.mem.startsWith(u8, line, "#")) return null;
    if (std.mem.startsWith(u8, line, "[")) return null;
    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return std.mem.trim(u8, line[0..eq_idx], " \t");
}

fn appendLockedKeyUnique(out: *std_io.StringBuilder, key: []const u8) !void {
    try appendCsvValueUnique(out, key);
}

fn appendCsvValueUnique(out: *std_io.StringBuilder, key: []const u8) !void {
    if (csvContains(out.items(), key)) return;
    if (out.items().len > 0) try out.append(',');
    try out.appendSlice(key);
}

fn csvContains(csv: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (std.mem.eql(u8, entry, key)) return true;
    }
    return false;
}

fn isManagedLockableKey(key: []const u8) bool {
    const lockable = [_][]const u8{
        "approval_mode",
        "sandbox",
        "api_profile",
        "api_role",
        "api_auth_required",
        "api_bearer_token",
        "api_oidc_issuer",
        "api_oidc_audience",
        "api_oidc_hs256_secret",
        "api_oidc_jwks_json",
        "api_oidc_jwks_file",
        "api_oidc_jwks_url",
        "api_oidc_jwks_cache_ttl_seconds",
        "egress_allowlist",
        "egress_denylist",
        "egress_allow_private_network_plaintext",
        "cloud_telemetry_opt_in",
        "control_plane_url",
        "control_plane_managed_settings_sync",
        "control_plane_managed_settings_verify_hash",
        "control_plane_policy_sync",
        "control_plane_policy_verify_hash",
        "feature_kill_switches",
        "session_encryption_enabled",
        "session_retention_days",
        "audit_retention_days",
        "privacy_redact_prompt_bodies",
        "update_require_signature",
        "update_pinned_version",
    };
    for (lockable) |candidate| {
        if (std.mem.eql(u8, key, candidate)) return true;
    }
    return false;
}

/// Warn once (per process) when a provider_api_key is stored in
/// plaintext config. Pattern-matches well-known API key prefixes so
/// we don't cry wolf on placeholder strings, empty values, or
/// `${VAR}`-shaped references the user is intentionally passing
/// through. The one-shot flag prevents a user with both
/// `provider_api_key` and `fallback_provider_api_key` set from
/// getting two identical stderr lines on every invocation.
var plaintext_secret_warned: bool = false;

/// Process-global gate. When true, `warnIfPlaintextSecret` stays
/// silent regardless of key/value pattern. main.zig flips it on for
/// `--quiet` / `--json` (and `--log-level error`) invocations so the
/// warning does not contaminate machine-readable pipelines. The
/// warning is security-relevant, so leave this off by default.
var plaintext_warning_silenced: bool = false;

pub fn silencePlaintextWarning() void {
    plaintext_warning_silenced = true;
}

fn warnIfPlaintextSecret(key: []const u8, value: []const u8) void {
    if (plaintext_secret_warned) return;
    if (plaintext_warning_silenced) return;
    const looks_like_secret = std.mem.startsWith(u8, value, "sk-") or
        std.mem.startsWith(u8, value, "ghp_") or
        std.mem.startsWith(u8, value, "gho_") or
        std.mem.startsWith(u8, value, "ghs_") or
        std.mem.startsWith(u8, value, "AKIA") or
        std.mem.startsWith(u8, value, "xoxb-") or
        std.mem.startsWith(u8, value, "xoxp-") or
        std.mem.startsWith(u8, value, "AIza");
    if (!looks_like_secret) return;
    plaintext_secret_warned = true;
    std_io.stderrWriter().print(
        "zcode: warning: {s} appears to hold a plaintext provider API key in config.toml.\n" ++
            "  - Move it to the OS keychain: `zcode keychain set <provider> <key>`\n" ++
            "  - Or put it in an env var (OPENAI_API_KEY, ANTHROPIC_API_KEY, ...)\n" ++
            "  - Then remove the `{s}` line from config.toml.\n",
        .{ key, key },
    ) catch {};
}

fn mergeLine(allocator: std.mem.Allocator, cfg: *Config, raw_line: []const u8) !void {
    var current_section: ?[]const u8 = null;
    try mergeLineWithMode(allocator, cfg, raw_line, null, false, &current_section);
}

/// POSIX-ish env-var name validation: `[A-Za-z_][A-Za-z0-9_]*`, non-empty,
/// no `=`. Mirrors session_env.set's name guard so a `[env]` table key cannot
/// smuggle a `=` or control byte into the spawned-tool environment.
fn isValidSettingsEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return false;
    for (name) |c| {
        if (c == '=') return false;
        if (c < 0x20 or c == 0x7f) return false;
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// settings-06: expand shell-style `${NAME}` and `$NAME` references inside an
/// `[env]` value against the process environment. Applied ONLY to `[env]`
/// values (and, in future, helper-command values) so existing scalar config
/// keys are never silently rewritten. An undefined variable expands to the
/// empty string (matching POSIX with `set -u` off) and emits a one-line stderr
/// warning so a typo'd reference is visible rather than silently swallowed.
///
/// The returned buffer is always a fresh allocation owned by the caller (even
/// when no reference is present), so the caller can free it unconditionally.
///
/// `$NAME` uses a conservative name charset (`[A-Za-z_][A-Za-z0-9_]*`) to match
/// POSIX shell variable names. A bare `$` (or `$` followed by a non-name byte)
/// is left literal. `${...}` with no closing brace is left literal too.
fn expandEnvVars(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c != '$') {
            try out.append(c);
            i += 1;
            continue;
        }
        // `$` at end of string -> literal.
        if (i + 1 >= value.len) {
            try out.append('$');
            i += 1;
            continue;
        }
        if (value[i + 1] == '{') {
            // `${NAME}` form. Find the closing brace.
            const close = std.mem.indexOfScalarPos(u8, value, i + 2, '}') orelse {
                // No closing brace -> leave the `${` literal and move on by one
                // byte so a stray `${` does not eat the rest of the string.
                try out.append('$');
                i += 1;
                continue;
            };
            const name = value[i + 2 .. close];
            try appendExpandedVar(&out, name);
            i = close + 1;
            continue;
        }
        // `$NAME` form. Scan a POSIX-ish name (must start with a letter or `_`).
        const first = value[i + 1];
        if (!(std.ascii.isAlphabetic(first) or first == '_')) {
            // `$` not followed by a name char -> literal `$`.
            try out.append('$');
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < value.len) : (j += 1) {
            const nc = value[j];
            if (!(std.ascii.isAlphanumeric(nc) or nc == '_')) break;
        }
        const name = value[i + 1 .. j];
        try appendExpandedVar(&out, name);
        i = j;
    }

    return out.toOwnedSlice();
}

/// Look up `name` in the process environment and append its value to `out`.
/// Undefined -> empty + one-line warning (documented behavior).
fn appendExpandedVar(out: *std_io.StringBuilder, name: []const u8) !void {
    if (@import("env.zig").getenv(name)) |env_value| {
        try out.appendSlice(env_value);
    } else {
        std_io.stderrWriter().print(
            "zcode: config warning: ${{{s}}} in [env] is not set; expanding to empty.\n",
            .{name},
        ) catch {};
    }
}

/// Route a single `KEY = value` line from an `[env]` table into
/// `cfg.settings_env` (settings-02). Validates the key, rejects control bytes
/// in the value (same rule as scalar keys), expands `${VAR}` references
/// (settings-06), and applies the provider-managed strip guard: when the spawn
/// env has CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST truthy, a provider-managed
/// routing var is dropped with a one-line note so the host's routing config is
/// not overridden by settings.
fn applySettingsEnvLine(
    allocator: std.mem.Allocator,
    cfg: *Config,
    key: []const u8,
    value: []const u8,
    source_path: ?[]const u8,
    strict_managed: bool,
) !void {
    if (!isValidSettingsEnvName(key)) {
        if (strict_managed) {
            std_io.stderrWriter().print(
                "zcode: managed config error: {s}: [env] key '{s}' is not a valid environment variable name. Managed files fail closed.\n",
                .{ source_path orelse "managed config", key },
            ) catch {};
            return error.InvalidManagedConfigValue;
        }
        std_io.stderrWriter().print(
            "zcode: config warning: ignoring [env] key '{s}' -- not a valid environment variable name.\n",
            .{key},
        ) catch {};
        return;
    }

    // Strip provider-managed routing vars when the host owns routing. The
    // flag itself stays un-overridable: a settings file cannot unset it.
    if (@import("managed_env.zig").isProviderManagedEnvVar(key) and
        @import("env.zig").isEnvTruthy(@import("managed_env.zig").PROVIDER_MANAGED_FLAG))
    {
        std_io.stderrWriter().print(
            "zcode: note: dropping settings env '{s}' -- host owns routing (CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST set).\n",
            .{key},
        ) catch {};
        return;
    }

    // settings-06: expand `${VAR}` / `$VAR` references against the process env
    // before storing. expandEnvVars always returns a fresh allocation, so free
    // it after upsert (upsertSettingsEnv dupes internally).
    const expanded = try expandEnvVars(allocator, value);
    defer allocator.free(expanded);
    try cfg.upsertSettingsEnv(allocator, key, expanded);
}

fn mergeLineWithMode(
    allocator: std.mem.Allocator,
    cfg: *Config,
    raw_line: []const u8,
    source_path: ?[]const u8,
    strict_managed: bool,
    current_section: *?[]const u8,
) !void {
    var line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return;
    if (std.mem.startsWith(u8, line, "#")) return;
    if (std.mem.startsWith(u8, line, "[")) {
        // Track the current TOML section so a following `[env]` table routes
        // its keys into cfg.settings_env (settings-02). Any other `[...]`
        // section keeps the historical skip-the-section behavior: its keys
        // are not recognized as scalar config and fall through to the
        // unknown-key warning. A malformed `[` line (no closing `]`) clears
        // the section so we do not silently treat subsequent keys as env.
        if (std.mem.indexOfScalar(u8, line, ']')) |close_idx| {
            current_section.* = std.mem.trim(u8, line[1..close_idx], " \t");
        } else {
            current_section.* = null;
        }
        return;
    }

    const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse return;

    const key = std.mem.trim(u8, line[0..eq_idx], " \t");
    var value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
    // Drop a TOML-style trailing `# comment` if it's outside any
    // quoted string. `stripQuotes` alone returned the value unchanged
    // because the trailing comment broke the outer-quote pairing.
    value = stripTrailingComment(value);
    value = std.mem.trimEnd(u8, value, " \t");
    value = stripQuotes(value);

    // Reject any C0 control byte or DEL inside a config value. A
    // stored newline / ANSI escape / NUL corrupts the TSV-style
    // `zcode config show` output and can smuggle lines into std.log
    // format strings when the value lands in a downstream warn.
    // No legitimate config value needs a control byte; `\t` is
    // rejected too to keep the rule dead-simple.
    for (value, 0..) |c, idx| {
        if (c < 0x20 or c == 0x7f) {
            if (strict_managed) {
                std_io.stderrWriter().print(
                    "zcode: managed config error: {s}: `{s}` contains a control byte (0x{x:0>2} at offset {d}). Managed files fail closed.\n",
                    .{ source_path orelse "managed config", key, c, idx },
                ) catch {};
                return error.InvalidManagedConfigValue;
            }
            std_io.stderrWriter().print(
                "zcode: config warning: ignoring '{s}' -- value contains a control byte (0x{x:0>2} at offset {d}).\n",
                .{ key, c, idx },
            ) catch {};
            return;
        }
    }

    // Inside an `[env]` table, the line is an environment variable, not a
    // scalar config key. Route it to cfg.settings_env (settings-02) instead
    // of applyKeyValue.
    if (current_section.*) |section| {
        if (std.mem.eql(u8, section, "env")) {
            try applySettingsEnvLine(allocator, cfg, key, value, source_path, strict_managed);
            return;
        }
        // A `[hooks]` section is recognized but not applied here: zcode has no
        // parsed hooks model yet (settings-03 scans for it textually for the
        // dangerous-key gate). Skip its body lines instead of treating them as
        // unknown scalar keys, which in strict managed mode would fail closed
        // before the approval gate ever ran.
        if (std.mem.eql(u8, section, "hooks")) return;
    }

    applyKeyValue(allocator, cfg, key, value) catch |err| switch (err) {
        error.UnknownConfigKey => {
            if (strict_managed) {
                const stderr = std_io.stderrWriter();
                stderr.print(
                    "zcode: managed config error: unknown key '{s}' in {s}. Managed files use strict schema validation and fail closed.\n",
                    .{ key, source_path orelse "managed config" },
                ) catch {};
                return error.UnknownManagedConfigKey;
            }
            const stderr = std_io.stderrWriter();
            stderr.print("zcode: config warning: unknown key '{s}' (ignored)\n", .{key}) catch {};
        },
        else => return err,
    };
}

/// Apply a single key=value pair to the config. Extracted from mergeLine
/// so the `/config set` slash command can reuse the same mapping. Returns
/// error.UnknownConfigKey when the key is not recognized (callers can
/// present a user-friendly message).
pub fn applyKeyValue(allocator: std.mem.Allocator, cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "default_provider")) {
        try setOwnedStringLower(allocator, &cfg.default_provider, value);
    } else if (std.mem.eql(u8, key, "default_model")) {
        try cfg.setOwnedString(allocator, &cfg.default_model, value);
    } else if (std.mem.eql(u8, key, "available_models")) {
        try cfg.setOwnedString(allocator, &cfg.available_models, value);
    } else if (std.mem.eql(u8, key, "fallback_provider")) {
        try cfg.setOwnedString(allocator, &cfg.fallback_provider, value);
    } else if (std.mem.eql(u8, key, "fallback_model")) {
        try cfg.setOwnedString(allocator, &cfg.fallback_model, value);
    } else if (std.mem.eql(u8, key, "small_fast_model")) {
        try cfg.setOwnedString(allocator, &cfg.small_fast_model, value);
    } else if (std.mem.eql(u8, key, "provider_api_key")) {
        warnIfPlaintextSecret(key, value);
        try cfg.setOwnedString(allocator, &cfg.provider_api_key, value);
    } else if (std.mem.eql(u8, key, "provider_base_url")) {
        try cfg.setOwnedString(allocator, &cfg.provider_base_url, value);
    } else if (std.mem.eql(u8, key, "local_base_url")) {
        try cfg.setOwnedString(allocator, &cfg.local_base_url, value);
    } else if (std.mem.eql(u8, key, "fallback_provider_api_key")) {
        warnIfPlaintextSecret(key, value);
        try cfg.setOwnedString(allocator, &cfg.fallback_provider_api_key, value);
    } else if (std.mem.eql(u8, key, "fallback_provider_base_url")) {
        try cfg.setOwnedString(allocator, &cfg.fallback_provider_base_url, value);
    } else if (std.mem.eql(u8, key, "provider_timeout_ms")) {
        cfg.provider_timeout_ms = try parseConfigInt(u32, key, value);
    } else if (std.mem.eql(u8, key, "provider_retry_count")) {
        cfg.provider_retry_count = try parseConfigInt(u8, key, value);
    } else if (std.mem.eql(u8, key, "profile")) {
        try cfg.setOwnedString(allocator, &cfg.profile, value);
    } else if (std.mem.eql(u8, key, "approval_mode")) {
        // Canonicalize to lowercase so a config.toml that wrote
        // `approval_mode = "TIERED-AUTO"` doesn't fail validation
        // (pass 47 did the same normalization for the CLI path).
        try setOwnedStringLower(allocator, &cfg.approval_mode, value);
    } else if (std.mem.eql(u8, key, "sandbox")) {
        try setOwnedStringLower(allocator, &cfg.sandbox, value);
    } else if (std.mem.eql(u8, key, "interactive_streaming")) {
        cfg.interactive_streaming = parseBool(value);
    } else if (std.mem.eql(u8, key, "intent_reprompt_enabled")) {
        cfg.intent_reprompt_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_fullscreen")) {
        cfg.ui_fullscreen = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_alt_screen")) {
        cfg.ui_alt_screen = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_spinner")) {
        cfg.ui_spinner = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_thinking_summary")) {
        cfg.ui_thinking_summary = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_brief_mode")) {
        cfg.ui_brief_mode = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_vim_mode")) {
        cfg.ui_vim_mode = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_auto_mode_opt_in_seen")) {
        cfg.ui_auto_mode_opt_in_seen = parseBool(value);
    } else if (std.mem.eql(u8, key, "default_mode")) {
        // ui-dialogs-03: persisted default permission mode set by the AutoMode
        // opt-in dialog's accept-default branch. Mirrors `permissions.defaultMode`.
        try setOwnedStringLower(allocator, &cfg.default_mode, value);
    } else if (std.mem.eql(u8, key, "skip_dangerous_mode_permission_prompt")) {
        cfg.skip_dangerous_mode_permission_prompt = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_idle_return_never_ask")) {
        // ui-dialogs-05: persisted when the user picks "Don't ask me again"
        // in the IdleReturnDialog so the return-from-idle nudge stops firing.
        cfg.ui_idle_return_never_ask = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_density")) {
        try cfg.setOwnedString(allocator, &cfg.ui_density, value);
    } else if (std.mem.eql(u8, key, "ui_leader_key")) {
        try cfg.setOwnedString(allocator, &cfg.ui_leader_key, value);
    } else if (std.mem.eql(u8, key, "ui_show_top_bar")) {
        cfg.ui_show_top_bar = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_show_shortcuts_panel")) {
        cfg.ui_show_shortcuts_panel = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_prompt_label")) {
        try cfg.setOwnedString(allocator, &cfg.ui_prompt_label, value);
    } else if (std.mem.eql(u8, key, "ui_transcript_max_lines")) {
        cfg.ui_transcript_max_lines = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "ui_show_scroll_hint")) {
        cfg.ui_show_scroll_hint = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_bottom_margin_rows")) {
        cfg.ui_bottom_margin_rows = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "ui_line_spacing")) {
        cfg.ui_line_spacing = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "ui_color_enabled")) {
        cfg.ui_color_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_theme")) {
        try cfg.setOwnedString(allocator, &cfg.ui_theme, value);
    } else if (std.mem.eql(u8, key, "ui_highlight_links")) {
        cfg.ui_highlight_links = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_highlight_paths")) {
        cfg.ui_highlight_paths = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_color_lists")) {
        cfg.ui_color_lists = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_highlight_code_blocks")) {
        cfg.ui_highlight_code_blocks = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_status_show_workspace")) {
        cfg.ui_status_show_workspace = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_status_show_model")) {
        cfg.ui_status_show_model = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_status_show_safety")) {
        cfg.ui_status_show_safety = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_status_show_tokens")) {
        cfg.ui_status_show_tokens = parseBool(value);
    } else if (std.mem.eql(u8, key, "ui_status_show_hint")) {
        cfg.ui_status_show_hint = parseBool(value);
    } else if (std.mem.eql(u8, key, "control_plane_url")) {
        try cfg.setOwnedString(allocator, &cfg.control_plane_url, value);
    } else if (std.mem.eql(u8, key, "control_plane_token")) {
        try cfg.setOwnedString(allocator, &cfg.control_plane_token, value);
    } else if (std.mem.eql(u8, key, "control_plane_policy_sync")) {
        cfg.control_plane_policy_sync = parseBool(value);
    } else if (std.mem.eql(u8, key, "control_plane_policy_verify_hash")) {
        cfg.control_plane_policy_verify_hash = parseBool(value);
    } else if (std.mem.eql(u8, key, "control_plane_managed_settings_sync")) {
        cfg.control_plane_managed_settings_sync = parseBool(value);
    } else if (std.mem.eql(u8, key, "control_plane_managed_settings_verify_hash")) {
        cfg.control_plane_managed_settings_verify_hash = parseBool(value);
    } else if (std.mem.eql(u8, key, "cloud_telemetry_opt_in")) {
        cfg.cloud_telemetry_opt_in = parseBool(value);
    } else if (std.mem.eql(u8, key, "egress_allowlist")) {
        try cfg.setOwnedString(allocator, &cfg.egress_allowlist, value);
    } else if (std.mem.eql(u8, key, "egress_denylist")) {
        try cfg.setOwnedString(allocator, &cfg.egress_denylist, value);
    } else if (std.mem.eql(u8, key, "egress_allow_private_network_plaintext")) {
        cfg.egress_allow_private_network_plaintext = parseBool(value);
    } else if (std.mem.eql(u8, key, "egress_allow_unix_sockets")) {
        cfg.egress_allow_unix_sockets = parseBool(value);
    } else if (std.mem.eql(u8, key, "egress_http_proxy_port")) {
        cfg.egress_http_proxy_port = try parseConfigInt(u16, key, value);
    } else if (std.mem.eql(u8, key, "egress_socks_proxy_port")) {
        cfg.egress_socks_proxy_port = try parseConfigInt(u16, key, value);
    } else if (std.mem.eql(u8, key, "model_context_window")) {
        cfg.model_context_window = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "reserved_output_tokens")) {
        cfg.reserved_output_tokens = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "reserved_reasoning_tokens")) {
        cfg.reserved_reasoning_tokens = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "instruction_file_cap_bytes")) {
        cfg.instruction_file_cap_bytes = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "instruction_total_cap_bytes")) {
        cfg.instruction_total_cap_bytes = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "instruction_imports_enabled")) {
        cfg.instruction_imports_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "instruction_import_max_depth")) {
        cfg.instruction_import_max_depth = try parseConfigInt(u8, key, value);
    } else if (std.mem.eql(u8, key, "prompt_cache_hints_enabled")) {
        cfg.prompt_cache_hints_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "feature_kill_switches")) {
        try cfg.setOwnedString(allocator, &cfg.feature_kill_switches, value);
    } else if (std.mem.eql(u8, key, "preferred_notif_channel")) {
        try cfg.setOwnedString(allocator, &cfg.preferred_notif_channel, value);
    } else if (std.mem.eql(u8, key, "output_style")) {
        try cfg.setOwnedString(allocator, &cfg.output_style, value);
    } else if (std.mem.eql(u8, key, "append_system_prompt")) {
        try cfg.setOwnedString(allocator, &cfg.append_system_prompt, value);
    } else if (std.mem.eql(u8, key, "max_history_turns")) {
        cfg.max_history_turns = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "max_tool_rounds")) {
        cfg.max_tool_rounds = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "max_budget_usd")) {
        cfg.max_budget_usd = try parseConfigFloat(key, value);
    } else if (std.mem.eql(u8, key, "max_structured_output_retries")) {
        cfg.max_structured_output_retries = try parseConfigInt(u32, key, value);
    } else if (std.mem.eql(u8, key, "tool_output_artifact_threshold_bytes")) {
        cfg.tool_output_artifact_threshold_bytes = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "mcp_tool_bridge_enabled")) {
        cfg.mcp_tool_bridge_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "browser_bridge_enabled")) {
        cfg.browser_bridge_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "browser_bridge_port")) {
        const port = try parseConfigInt(u16, key, value);
        cfg.browser_bridge_port = if (port == 0) 9222 else port;
    } else if (std.mem.eql(u8, key, "api_profile")) {
        try setOwnedStringLower(allocator, &cfg.api_profile, value);
    } else if (std.mem.eql(u8, key, "api_role")) {
        try setOwnedStringLower(allocator, &cfg.api_role, value);
    } else if (std.mem.eql(u8, key, "api_auth_required")) {
        cfg.api_auth_required = parseBool(value);
    } else if (std.mem.eql(u8, key, "api_bearer_token")) {
        try cfg.setOwnedString(allocator, &cfg.api_bearer_token, value);
    } else if (std.mem.eql(u8, key, "api_oidc_issuer")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_issuer, value);
    } else if (std.mem.eql(u8, key, "api_oidc_audience")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_audience, value);
    } else if (std.mem.eql(u8, key, "api_oidc_hs256_secret")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_hs256_secret, value);
    } else if (std.mem.eql(u8, key, "api_oidc_jwks_json")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_json, value);
    } else if (std.mem.eql(u8, key, "api_oidc_jwks_file")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_file, value);
    } else if (std.mem.eql(u8, key, "api_oidc_jwks_url")) {
        try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_url, value);
    } else if (std.mem.eql(u8, key, "api_oidc_jwks_cache_ttl_seconds")) {
        cfg.api_oidc_jwks_cache_ttl_seconds = try parseConfigInt(u32, key, value);
    } else if (std.mem.eql(u8, key, "update_require_signature")) {
        cfg.update_require_signature = parseBool(value);
    } else if (std.mem.eql(u8, key, "update_pinned_version")) {
        try cfg.setOwnedString(allocator, &cfg.update_pinned_version, value);
    } else if (std.mem.eql(u8, key, "session_encryption_enabled")) {
        cfg.session_encryption_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "privacy_redact_prompt_bodies")) {
        cfg.privacy_redact_prompt_bodies = parseBool(value);
    } else if (std.mem.eql(u8, key, "session_retention_days")) {
        // Cap at 10 years so a typo (`session_retention_days = 100000000`)
        // doesn't make the i128 cutoff arithmetic do something silly.
        const parsed = try parseConfigInt(u32, key, value);
        cfg.session_retention_days = @min(parsed, 3650);
    } else if (std.mem.eql(u8, key, "audit_retention_days")) {
        const parsed = try parseConfigInt(u32, key, value);
        cfg.audit_retention_days = @min(parsed, 3650);
    } else if (std.mem.eql(u8, key, "preprocessor_enabled")) {
        cfg.preprocessor_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "preprocessor_provider")) {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_provider, value);
    } else if (std.mem.eql(u8, key, "preprocessor_model")) {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_model, value);
    } else if (std.mem.eql(u8, key, "preprocessor_base_url")) {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_base_url, value);
    } else if (std.mem.eql(u8, key, "preprocessor_max_output_tokens")) {
        cfg.preprocessor_max_output_tokens = try parseConfigInt(usize, key, value);
    } else if (std.mem.eql(u8, key, "preprocessor_api_key")) {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_api_key, value);
    } else if (std.mem.eql(u8, key, "preferred_language") or
        std.mem.eql(u8, key, "language"))
    {
        try cfg.setOwnedString(allocator, &cfg.preferred_language, value);
    } else if (std.mem.eql(u8, key, "auto_memory_enabled")) {
        cfg.auto_memory_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "auto_memory_directory")) {
        try cfg.setOwnedString(allocator, &cfg.auto_memory_directory, value);
    } else if (std.mem.eql(u8, key, "auto_dream_enabled")) {
        cfg.auto_dream_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "auto_dream_min_hours")) {
        cfg.auto_dream_min_hours = try parseConfigInt(u32, key, value);
    } else if (std.mem.eql(u8, key, "auto_dream_min_sessions")) {
        cfg.auto_dream_min_sessions = try parseConfigInt(u32, key, value);
    } else if (std.mem.eql(u8, key, "spinner_tips_enabled")) {
        cfg.spinner_tips_enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "spinner_tips_custom")) {
        try cfg.setOwnedString(allocator, &cfg.spinner_tips_custom, value);
    } else if (std.mem.eql(u8, key, "spinner_tips_exclude_default")) {
        cfg.spinner_tips_exclude_default = parseBool(value);
    } else if (std.mem.eql(u8, key, "reasoning_effort") or
        std.mem.eql(u8, key, "effort_level"))
    {
        // Validate against the canonical effort vocabulary so a typo in the
        // config file fails closed instead of silently storing garbage that
        // the startup resolver later ignores. fromString accepts the same
        // spellings as `/effort` (auto/unset, low, medium/med, high,
        // max/maximum); store the canonical lower-case name.
        const eff = @import("types.zig").ReasoningEffort.fromString(value) orelse
            return error.InvalidConfigValue;
        try cfg.setOwnedString(allocator, &cfg.reasoning_effort, eff.toString());
    } else {
        // Let callers decide whether an unknown key is a warning
        // (user config) or a fail-closed error (managed config).
        return error.UnknownConfigKey;
    }
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len < 2) return v;
    if ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\'')) {
        return v[1 .. v.len - 1];
    }
    return v;
}

/// Wrap `std.fmt.parseInt` so a bad numeric config value produces a
/// targeted stderr line before returning the error. Before this
/// helper, `provider_timeout_ms = 99999999999` surfaced as the bare
/// `error: failed to load config: Overflow` with no hint which key
/// was bad or what range it accepted.
/// Parse an f64 config value (e.g. max_budget_usd). A malformed value prints a
/// clear diagnostic to stderr and returns the parse error, matching
/// parseConfigInt's contract.
fn parseConfigFloat(key: []const u8, value: []const u8) !f64 {
    return std.fmt.parseFloat(f64, value) catch |err| {
        const stderr = std_io.stderrWriter();
        stderr.print(
            "zcode: config error: `{s} = {s}` is not a valid number.\n",
            .{ key, value },
        ) catch {};
        return err;
    };
}

fn parseConfigInt(comptime T: type, key: []const u8, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch |err| {
        const stderr = std_io.stderrWriter();
        const max_s = blk: {
            if (T == u8) break :blk "255";
            if (T == u16) break :blk "65535";
            if (T == u32) break :blk "4294967295";
            if (T == u64) break :blk "18446744073709551615";
            if (T == usize) break :blk "platform-dependent (max usize)";
            break :blk "out of range";
        };
        switch (err) {
            error.Overflow => stderr.print(
                "zcode: config error: `{s} = {s}` is out of range (max for this field: {s}).\n",
                .{ key, value, max_s },
            ) catch {},
            error.InvalidCharacter => stderr.print(
                "zcode: config error: `{s} = {s}` is not a valid non-negative integer.\n",
                .{ key, value },
            ) catch {},
        }
        return err;
    };
}

/// Strip a TOML-style trailing `# comment` from a value, but only
/// when the `#` is outside any quoted string. Before this helper,
///   default_model = "foo" # comment here
/// stored the literal `"foo" # comment here` (including the outer
/// quotes, because stripQuotes looks for balanced edges and the
/// trailing ` # comment here` made it unbalanced).
fn stripTrailingComment(v: []const u8) []const u8 {
    var in_double = false;
    var in_single = false;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        const c = v[i];
        if (in_double) {
            if (c == '\\' and i + 1 < v.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_double = false;
            continue;
        }
        if (in_single) {
            if (c == '\'') in_single = false;
            continue;
        }
        switch (c) {
            '"' => in_double = true,
            '\'' => in_single = true,
            '#' => return std.mem.trimEnd(u8, v[0..i], " \t"),
            else => {},
        }
    }
    return v;
}

fn parseBool(value: []const u8) bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "on")) {
        return true;
    }
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "off") or value.len == 0) {
        return false;
    }
    // Anything else is a typo or garbage; warn so the operator can
    // catch the misconfiguration instead of it silently parsing to
    // false (e.g. `ui_fullscreen = ture`).
    std.log.warn("config: unrecognized boolean value `{s}`; treating as false", .{value});
    return false;
}

const QualifiedProviderModel = struct {
    provider: []const u8,
    model: []const u8,
};

fn parseQualifiedProviderModel(raw: []const u8) ?QualifiedProviderModel {
    if (std.mem.indexOfScalar(u8, raw, '/')) |slash_idx| {
        const provider = std.mem.trim(u8, raw[0..slash_idx], " \t");
        const model = std.mem.trim(u8, raw[slash_idx + 1 ..], " \t");
        if (provider.len > 0 and model.len > 0 and isKnownProviderName(provider)) {
            return .{
                .provider = provider,
                .model = model,
            };
        }
    }
    return null;
}

fn isKnownProviderName(name: []const u8) bool {
    return std.mem.eql(u8, name, "openai") or
        std.mem.eql(u8, name, "openai-compatible") or
        std.mem.eql(u8, name, "anthropic") or
        std.mem.eql(u8, name, "gemini") or
        std.mem.eql(u8, name, "deepseek") or
        std.mem.eql(u8, name, "groq") or
        std.mem.eql(u8, name, "openrouter") or
        std.mem.eql(u8, name, "azure") or
        std.mem.eql(u8, name, "azure-openai") or
        std.mem.eql(u8, name, "local") or
        std.mem.eql(u8, name, "ollama") or
        std.mem.eql(u8, name, "mock");
}

/// Canonicalize an enum-style config value to lowercase ASCII so
/// downstream `std.mem.eql` comparisons against `"tiered-auto"` /
/// `"danger-full-access"` don't miss a user who typed the same
/// string in uppercase. Case-insensitivity is applied at accept
/// time; the stored value is always lowercase from this point on.
fn dupLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

fn setOwnedStringLower(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    const next = try dupLower(allocator, value);
    allocator.free(target.*);
    target.* = next;
}

fn applyCliOverrides(allocator: std.mem.Allocator, cfg: *Config, opts: *const cli.CliOptions) !void {
    if (opts.provider) |v| {
        try setOwnedStringLower(allocator, &cfg.default_provider, v);
    }
    if (opts.model) |v| {
        try cfg.setOwnedString(allocator, &cfg.default_model, v);
    }
    if (opts.profile) |v| {
        try cfg.setOwnedString(allocator, &cfg.profile, v);
    }
    if (opts.approval_mode) |v| {
        try setOwnedStringLower(allocator, &cfg.approval_mode, v);
    }
    if (opts.sandbox) |v| {
        try setOwnedStringLower(allocator, &cfg.sandbox, v);
    }
    if (opts.prompt_label) |v| {
        try cfg.setOwnedString(allocator, &cfg.ui_prompt_label, v);
    }
    if (opts.output_style) |v| {
        try cfg.setOwnedString(allocator, &cfg.output_style, v);
    }
    if (opts.append_system_prompt) |v| {
        // CLI override replaces whatever came from config.toml.
        // Ported from claude-code-main/src/main.tsx
        // --append-system-prompt and --append-system-prompt-file
        // flags so zcode pipelines can stick a one-shot prompt
        // on top of the default context without editing config:
        //   zcode run --append-system-prompt "Follow TDD" "fix bug"
        //   zcode run --append-system-prompt-file style.md "refactor"
        try cfg.setOwnedString(allocator, &cfg.append_system_prompt, v);
    }
    if (opts.transcript_max_lines) |v| {
        cfg.ui_transcript_max_lines = v;
    }
    if (opts.no_fullscreen) {
        cfg.ui_fullscreen = false;
    }
    if (opts.no_spinner) {
        cfg.ui_spinner = false;
    }
    if (opts.no_thinking_summary) {
        cfg.ui_thinking_summary = false;
    }
    if (opts.no_stream) {
        cfg.interactive_streaming = false;
    }
    if (opts.no_color) {
        cfg.ui_color_enabled = false;
    }

    var preprocessor_touched = false;
    if (opts.preprocessor_enabled) |enabled| {
        cfg.preprocessor_enabled = enabled;
        preprocessor_touched = true;
    }
    if (opts.preprocessor_provider) |value| {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_provider, value);
        preprocessor_touched = true;
    }
    if (opts.preprocessor_model) |raw_model| {
        if (opts.preprocessor_provider == null) {
            if (parseQualifiedProviderModel(raw_model)) |qualified| {
                try cfg.setOwnedString(allocator, &cfg.preprocessor_provider, qualified.provider);
                try cfg.setOwnedString(allocator, &cfg.preprocessor_model, qualified.model);
            } else {
                try cfg.setOwnedString(allocator, &cfg.preprocessor_model, raw_model);
            }
        } else {
            try cfg.setOwnedString(allocator, &cfg.preprocessor_model, raw_model);
        }
        preprocessor_touched = true;
    }
    if (opts.preprocessor_base_url) |value| {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_base_url, value);
        preprocessor_touched = true;
    }
    if (opts.preprocessor_api_key) |value| {
        try cfg.setOwnedString(allocator, &cfg.preprocessor_api_key, value);
        preprocessor_touched = true;
    }
    if (opts.preprocessor_max_output_tokens) |value| {
        cfg.preprocessor_max_output_tokens = value;
        preprocessor_touched = true;
    }

    if (preprocessor_touched and (opts.preprocessor_enabled == null or opts.preprocessor_enabled.?)) {
        cfg.preprocessor_enabled = true;
        if (cfg.preprocessor_provider.len == 0) {
            try cfg.setOwnedString(allocator, &cfg.preprocessor_provider, opts.provider orelse cfg.default_provider);
        }
        if (cfg.preprocessor_model.len == 0) {
            try cfg.setOwnedString(allocator, &cfg.preprocessor_model, opts.model orelse cfg.default_model);
        }
    }
}

/// Persist a key=value pair to the user config file (~/.zcode/config.toml).
/// If the key already exists, its value is updated in place. Otherwise, the
/// key=value line is appended. Creates the file if it does not exist.
pub fn persistUserConfigField(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    const cfg_path = resolved.user_config_path;
    try paths.ensureDir(std.fs.path.dirname(cfg_path) orelse return error.InvalidPath);

    // Read existing content (empty if file doesn't exist)
    const existing = std.Io.Dir.cwd().readFileAlloc(rt.io, cfg_path, allocator, .limited(1_048_576)) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    // Build new content: replace existing key or append
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    // `splitScalar` on "a\nb\n" yields ["a", "b", ""] — the empty trailing
    // segment represents the text after the final newline. Rewriting each
    // segment as `segment + "\n"` would append an extra "\n" per call and
    // grow the file unbounded across repeated writes. Track how many
    // segments exist and skip emitting a trailing newline for the last
    // empty segment (which means the source ended with "\n").
    var segments = std.array_list.Managed([]const u8).init(allocator);
    defer segments.deinit();
    {
        var it = std.mem.splitScalar(u8, existing, '\n');
        while (it.next()) |line| try segments.append(line);
    }

    var found = false;
    for (segments.items, 0..) |line, i| {
        const is_last = i == segments.items.len - 1;
        const is_last_empty_from_terminator = is_last and line.len == 0;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=');
            if (eq_idx) |idx| {
                const line_key = std.mem.trim(u8, trimmed[0..idx], " \t");
                if (std.mem.eql(u8, line_key, key)) {
                    try out.writer().print("{s} = {s}\n", .{ key, value });
                    found = true;
                    continue;
                }
            }
        }
        if (is_last_empty_from_terminator) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }

    if (!found) {
        try out.writer().print("{s} = {s}\n", .{ key, value });
    }

    // Write atomically via tmp+rename so a crash mid-write cannot leave
    // the user config file empty or half-written.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ cfg_path, clock.nowNanos() });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, out.items());
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("config: chmod failed: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, cfg_path, rt.io);
}

pub fn resolveWorkingDirectory(allocator: std.mem.Allocator, opts: *const cli.CliOptions) ![]u8 {
    if (opts.cwd) |value| {
        // Validate the --cwd target now so a typo doesn't cascade
        // into opaque downstream errors ("tool execution error:
        // FileNotFound" with no hint which path was wrong). We do NOT
        // chdir here; the caller decides whether to chdir. We only
        // assert that `value` names an existing directory the caller
        // can open.
        var dir = std.Io.Dir.cwd().openDir(rt.io, value, .{}) catch |err| {
            const stderr = std_io.stderrWriter();
            switch (err) {
                error.FileNotFound => stderr.print(
                    "error: --cwd: no such directory: {s}\n",
                    .{value},
                ) catch {},
                error.NotDir => stderr.print(
                    "error: --cwd: path is not a directory: {s}\n  - Expected a directory, got a regular file.\n",
                    .{value},
                ) catch {},
                error.AccessDenied => stderr.print(
                    "error: --cwd: permission denied: {s}\n  - Check the directory's mode and owner; zcode does not elevate.\n",
                    .{value},
                ) catch {},
                else => stderr.print(
                    "error: --cwd: cannot open {s} ({s}).\n",
                    .{ value, @errorName(err) },
                ) catch {},
            }
            return error.InvalidCwd;
        };
        dir.close(rt.io);
        return allocator.dupe(u8, value);
    }
    // currentPathAlloc returns a sentinel-terminated [:0]u8 (allocation is
    // len+1). Callers free the result as a plain []u8 (len), which is an
    // allocation-size mismatch the safety allocator aborts on. Re-dupe to an
    // exact-length []u8 and free the sentinel buffer here so alloc == free.
    const cwd_z = try std.process.currentPathAlloc(rt.io, allocator);
    defer allocator.free(cwd_z);
    return allocator.dupe(u8, cwd_z);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "strip quotes" {
    try testing.expectEqualStrings("abc", stripQuotes("\"abc\""));
    try testing.expectEqualStrings("abc", stripQuotes("abc"));
}

test "merge fallback provider fields" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "fallback_provider = \"local\"");
    try mergeLine(allocator, &cfg, "fallback_model = \"qwen2.5-coder\"");
    try mergeLine(allocator, &cfg, "provider_base_url = \"https://api.deepseek.com\"");
    try mergeLine(allocator, &cfg, "provider_api_key = \"abc\"");
    try mergeLine(allocator, &cfg, "fallback_provider_base_url = \"http://127.0.0.1:11434\"");
    try mergeLine(allocator, &cfg, "fallback_provider_api_key = \"local-key\"");

    try testing.expectEqualStrings("local", cfg.fallback_provider);
    try testing.expectEqualStrings("qwen2.5-coder", cfg.fallback_model);
    try testing.expectEqualStrings("https://api.deepseek.com", cfg.provider_base_url);
    try testing.expectEqualStrings("abc", cfg.provider_api_key);
    try testing.expectEqualStrings("http://127.0.0.1:11434", cfg.fallback_provider_base_url);
    try testing.expectEqualStrings("local-key", cfg.fallback_provider_api_key);
}

test "merge local base url" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "local_base_url = \"http://192.168.1.247:8081\"");
    try testing.expectEqualStrings("http://192.168.1.247:8081", cfg.local_base_url);
}

test "merge ui theme" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "ui_theme = dark-ansi");
    try testing.expectEqualStrings("dark-ansi", cfg.ui_theme);
}

test "merge available models list" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "available_models = \"kimi-k2.5,kimi-k2-thinking\"");
    try testing.expectEqualStrings("kimi-k2.5,kimi-k2-thinking", cfg.available_models);
}

test "merge output style" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "output_style = investigative");
    try testing.expectEqualStrings("investigative", cfg.output_style);
}

test "merge preferred notif channel" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    // Default is "auto".
    try testing.expectEqualStrings("auto", cfg.preferred_notif_channel);

    try mergeLine(allocator, &cfg, "preferred_notif_channel = terminal_bell");
    try testing.expectEqualStrings("terminal_bell", cfg.preferred_notif_channel);

    try mergeLine(allocator, &cfg, "preferred_notif_channel = notifications_disabled");
    try testing.expectEqualStrings("notifications_disabled", cfg.preferred_notif_channel);
}

test "merge control plane policy sync flags" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "control_plane_policy_sync = true");
    try mergeLine(allocator, &cfg, "control_plane_policy_verify_hash = false");

    try testing.expect(cfg.control_plane_policy_sync);
    try testing.expect(!cfg.control_plane_policy_verify_hash);
}

test "merge API auth and OIDC fields" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "api_profile = FULL");
    try mergeLine(allocator, &cfg, "api_role = Editor");
    try mergeLine(allocator, &cfg, "api_auth_required = true");
    try mergeLine(allocator, &cfg, "api_bearer_token = local-secret");
    try mergeLine(allocator, &cfg, "api_oidc_issuer = https://issuer.example");
    try mergeLine(allocator, &cfg, "api_oidc_audience = zcode");
    try mergeLine(allocator, &cfg, "api_oidc_hs256_secret = shared-secret");
    try mergeLine(allocator, &cfg, "api_oidc_jwks_json = {\"keys\":[]}");
    try mergeLine(allocator, &cfg, "api_oidc_jwks_file = /etc/zcode/jwks.json");
    try mergeLine(allocator, &cfg, "api_oidc_jwks_url = https://issuer.example/.well-known/jwks.json");
    try mergeLine(allocator, &cfg, "api_oidc_jwks_cache_ttl_seconds = 120");

    try testing.expectEqualStrings("full", cfg.api_profile);
    try testing.expectEqualStrings("editor", cfg.api_role);
    try testing.expect(cfg.api_auth_required);
    try testing.expectEqualStrings("local-secret", cfg.api_bearer_token);
    try testing.expectEqualStrings("https://issuer.example", cfg.api_oidc_issuer);
    try testing.expectEqualStrings("zcode", cfg.api_oidc_audience);
    try testing.expectEqualStrings("shared-secret", cfg.api_oidc_hs256_secret);
    try testing.expectEqualStrings("{\"keys\":[]}", cfg.api_oidc_jwks_json);
    try testing.expectEqualStrings("/etc/zcode/jwks.json", cfg.api_oidc_jwks_file);
    try testing.expectEqualStrings("https://issuer.example/.well-known/jwks.json", cfg.api_oidc_jwks_url);
    try testing.expectEqual(@as(u32, 120), cfg.api_oidc_jwks_cache_ttl_seconds);
}

test "parseBool accepts yes and 1" {
    try testing.expect(parseBool("true"));
    try testing.expect(parseBool("1"));
    try testing.expect(parseBool("yes"));
    try testing.expect(!parseBool("false"));
    try testing.expect(!parseBool("0"));
    try testing.expect(!parseBool("no"));
}

test "merge ignores comments and section headers" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "# this is a comment");
    try mergeLine(allocator, &cfg, "[section]");
    try mergeLine(allocator, &cfg, "");
    // Should not crash and config should remain at defaults.
    try testing.expectEqualStrings("anthropic", cfg.default_provider);
}

test "merge preprocessor fields" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "preprocessor_enabled = true");
    try mergeLine(allocator, &cfg, "preprocessor_provider = openai");
    try mergeLine(allocator, &cfg, "preprocessor_model = gpt-4.1-mini");
    try mergeLine(allocator, &cfg, "preprocessor_base_url = https://api.example.test/v1");
    try mergeLine(allocator, &cfg, "preprocessor_max_output_tokens = 500");
    try mergeLine(allocator, &cfg, "preprocessor_api_key = sk-test-key");

    try testing.expect(cfg.preprocessor_enabled);
    try testing.expectEqualStrings("openai", cfg.preprocessor_provider);
    try testing.expectEqualStrings("gpt-4.1-mini", cfg.preprocessor_model);
    try testing.expectEqualStrings("https://api.example.test/v1", cfg.preprocessor_base_url);
    try testing.expectEqual(@as(usize, 500), cfg.preprocessor_max_output_tokens);
    try testing.expectEqualStrings("sk-test-key", cfg.preprocessor_api_key);
}

test "applyCliOverrides enables preprocessor from qualified model flag" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    const opts: cli.CliOptions = .{
        .preprocessor_model = "gemini/gemini-2.5-flash",
    };

    try applyCliOverrides(allocator, &cfg, &opts);

    try testing.expect(cfg.preprocessor_enabled);
    try testing.expectEqualStrings("gemini", cfg.preprocessor_provider);
    try testing.expectEqualStrings("gemini-2.5-flash", cfg.preprocessor_model);
}

test "applyCliOverrides enables preprocessor from defaults when flag is set" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    const opts: cli.CliOptions = .{
        .preprocessor_enabled = true,
    };

    try applyCliOverrides(allocator, &cfg, &opts);

    try testing.expect(cfg.preprocessor_enabled);
    try testing.expectEqualStrings("anthropic", cfg.preprocessor_provider);
    try testing.expectEqualStrings("claude-opus-4-6", cfg.preprocessor_model);
}

test "applyCliOverrides preserves slash model when provider is explicit" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    const opts: cli.CliOptions = .{
        .preprocessor_provider = "openrouter",
        .preprocessor_model = "anthropic/claude-sonnet-4",
    };

    try applyCliOverrides(allocator, &cfg, &opts);

    try testing.expect(cfg.preprocessor_enabled);
    try testing.expectEqualStrings("openrouter", cfg.preprocessor_provider);
    try testing.expectEqualStrings("anthropic/claude-sonnet-4", cfg.preprocessor_model);
}

test "applyCliOverrides sets output style" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    const opts: cli.CliOptions = .{
        .output_style = "learning",
    };

    try applyCliOverrides(allocator, &cfg, &opts);
    try testing.expectEqualStrings("learning", cfg.output_style);
}

test "merge ui and runtime behavior fields" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "interactive_streaming = false");
    try mergeLine(allocator, &cfg, "intent_reprompt_enabled = false");
    try mergeLine(allocator, &cfg, "ui_fullscreen = false");
    try mergeLine(allocator, &cfg, "ui_alt_screen = false");
    try mergeLine(allocator, &cfg, "ui_spinner = false");
    try mergeLine(allocator, &cfg, "ui_thinking_summary = false");
    try mergeLine(allocator, &cfg, "ui_brief_mode = true");
    try mergeLine(allocator, &cfg, "ui_vim_mode = true");
    try mergeLine(allocator, &cfg, "ui_auto_mode_opt_in_seen = true");
    try mergeLine(allocator, &cfg, "skip_dangerous_mode_permission_prompt = true");
    try mergeLine(allocator, &cfg, "ui_density = clean");
    try mergeLine(allocator, &cfg, "ui_leader_key = ctrl+g");
    try mergeLine(allocator, &cfg, "ui_show_top_bar = false");
    try mergeLine(allocator, &cfg, "ui_show_shortcuts_panel = false");
    try mergeLine(allocator, &cfg, "ui_prompt_label = \">>>\"");
    try mergeLine(allocator, &cfg, "ui_transcript_max_lines = 1200");
    try mergeLine(allocator, &cfg, "ui_show_scroll_hint = false");
    try mergeLine(allocator, &cfg, "ui_bottom_margin_rows = 2");
    try mergeLine(allocator, &cfg, "ui_line_spacing = 1");
    try mergeLine(allocator, &cfg, "ui_color_enabled = false");
    try mergeLine(allocator, &cfg, "ui_highlight_links = false");
    try mergeLine(allocator, &cfg, "ui_highlight_paths = false");
    try mergeLine(allocator, &cfg, "ui_color_lists = false");
    try mergeLine(allocator, &cfg, "ui_highlight_code_blocks = false");
    try mergeLine(allocator, &cfg, "ui_status_show_workspace = false");
    try mergeLine(allocator, &cfg, "ui_status_show_model = false");
    try mergeLine(allocator, &cfg, "ui_status_show_safety = false");
    try mergeLine(allocator, &cfg, "ui_status_show_tokens = false");
    try mergeLine(allocator, &cfg, "ui_status_show_hint = false");
    try mergeLine(allocator, &cfg, "provider_timeout_ms = 45000");
    try mergeLine(allocator, &cfg, "provider_retry_count = 4");
    try mergeLine(allocator, &cfg, "instruction_imports_enabled = false");
    try mergeLine(allocator, &cfg, "instruction_import_max_depth = 3");
    try mergeLine(allocator, &cfg, "prompt_cache_hints_enabled = false");
    try mergeLine(allocator, &cfg, "feature_kill_switches = \"browser_bridge,preprocessor\"");
    try mergeLine(allocator, &cfg, "append_system_prompt = \"extra rules\"");
    try mergeLine(allocator, &cfg, "session_encryption_enabled = true");
    try mergeLine(allocator, &cfg, "session_retention_days = 45");
    try mergeLine(allocator, &cfg, "audit_retention_days = 120");
    try mergeLine(allocator, &cfg, "egress_allowlist = \"api.openai.com,*.anthropic.com\"");
    try mergeLine(allocator, &cfg, "egress_allow_private_network_plaintext = true");
    try mergeLine(allocator, &cfg, "tool_output_artifact_threshold_bytes = 8192");
    try mergeLine(allocator, &cfg, "control_plane_managed_settings_sync = true");
    try mergeLine(allocator, &cfg, "control_plane_managed_settings_verify_hash = false");
    try mergeLine(allocator, &cfg, "update_require_signature = true");
    try mergeLine(allocator, &cfg, "update_pinned_version = 1.2.3");

    try testing.expect(!cfg.interactive_streaming);
    try testing.expect(!cfg.intent_reprompt_enabled);
    try testing.expect(!cfg.ui_fullscreen);
    try testing.expect(!cfg.ui_alt_screen);
    try testing.expect(!cfg.ui_spinner);
    try testing.expect(!cfg.ui_thinking_summary);
    try testing.expect(cfg.ui_brief_mode);
    try testing.expect(cfg.ui_vim_mode);
    try testing.expect(cfg.ui_auto_mode_opt_in_seen);
    try testing.expect(cfg.skip_dangerous_mode_permission_prompt);
    try testing.expectEqualStrings("clean", cfg.ui_density);
    try testing.expectEqualStrings("ctrl+g", cfg.ui_leader_key);
    try testing.expect(!cfg.ui_show_top_bar);
    try testing.expect(!cfg.ui_show_shortcuts_panel);
    try testing.expectEqualStrings(">>>", cfg.ui_prompt_label);
    try testing.expectEqual(@as(usize, 1200), cfg.ui_transcript_max_lines);
    try testing.expect(!cfg.ui_show_scroll_hint);
    try testing.expectEqual(@as(usize, 2), cfg.ui_bottom_margin_rows);
    try testing.expectEqual(@as(usize, 1), cfg.ui_line_spacing);
    try testing.expect(!cfg.ui_color_enabled);
    try testing.expect(!cfg.ui_highlight_links);
    try testing.expect(!cfg.ui_highlight_paths);
    try testing.expect(!cfg.ui_color_lists);
    try testing.expect(!cfg.ui_highlight_code_blocks);
    try testing.expect(!cfg.ui_status_show_workspace);
    try testing.expect(!cfg.ui_status_show_model);
    try testing.expect(!cfg.ui_status_show_safety);
    try testing.expect(!cfg.ui_status_show_tokens);
    try testing.expect(!cfg.ui_status_show_hint);
    try testing.expectEqual(@as(u32, 45_000), cfg.provider_timeout_ms);
    try testing.expectEqual(@as(u8, 4), cfg.provider_retry_count);
    try testing.expect(!cfg.instruction_imports_enabled);
    try testing.expectEqual(@as(u8, 3), cfg.instruction_import_max_depth);
    try testing.expect(!cfg.prompt_cache_hints_enabled);
    try testing.expectEqualStrings("browser_bridge,preprocessor", cfg.feature_kill_switches);
    try testing.expectEqualStrings("extra rules", cfg.append_system_prompt);
    try testing.expect(cfg.session_encryption_enabled);
    try testing.expectEqual(@as(u32, 45), cfg.session_retention_days);
    try testing.expectEqual(@as(u32, 120), cfg.audit_retention_days);
    try testing.expectEqualStrings("api.openai.com,*.anthropic.com", cfg.egress_allowlist);
    try testing.expect(cfg.egress_allow_private_network_plaintext);
    try testing.expectEqual(@as(usize, 8192), cfg.tool_output_artifact_threshold_bytes);
    try testing.expect(cfg.control_plane_managed_settings_sync);
    try testing.expect(!cfg.control_plane_managed_settings_verify_hash);
    try testing.expect(cfg.update_require_signature);
    try testing.expectEqualStrings("1.2.3", cfg.update_pinned_version);
}

test "merge auto-dream settings" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    // Defaults: tri-state unset, thresholds 24h / 5 sessions.
    try testing.expectEqual(@as(?bool, null), cfg.auto_dream_enabled);
    try testing.expectEqual(@as(u32, 24), cfg.auto_dream_min_hours);
    try testing.expectEqual(@as(u32, 5), cfg.auto_dream_min_sessions);

    try mergeLine(allocator, &cfg, "auto_dream_enabled = false");
    try mergeLine(allocator, &cfg, "auto_dream_min_hours = 12");
    try mergeLine(allocator, &cfg, "auto_dream_min_sessions = 3");

    try testing.expectEqual(@as(?bool, false), cfg.auto_dream_enabled);
    try testing.expectEqual(@as(u32, 12), cfg.auto_dream_min_hours);
    try testing.expectEqual(@as(u32, 3), cfg.auto_dream_min_sessions);
}

test "merge spinner-tips settings" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    // Defaults: enabled, no custom tips, defaults not excluded.
    try testing.expectEqual(true, cfg.spinner_tips_enabled);
    try testing.expectEqualStrings("", cfg.spinner_tips_custom);
    try testing.expectEqual(false, cfg.spinner_tips_exclude_default);

    try mergeLine(allocator, &cfg, "spinner_tips_enabled = false");
    try mergeLine(allocator, &cfg, "spinner_tips_exclude_default = true");
    try mergeLine(allocator, &cfg, "spinner_tips_custom = Custom tip one;Custom tip two");

    try testing.expectEqual(false, cfg.spinner_tips_enabled);
    try testing.expectEqual(true, cfg.spinner_tips_exclude_default);
    try testing.expectEqualStrings("Custom tip one;Custom tip two", cfg.spinner_tips_custom);
}

test "managed config records lockable keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const managed_body =
        \\api_auth_required = true
        \\api_profile = read-only
        \\default_model = "not-locked"
        \\session_encryption_enabled = true
        \\update_require_signature = true
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = managed_body });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    var summary = (try mergeManagedConfigSet(testing.allocator, &cfg, managed_path)).?;
    defer summary.deinit();
    try testing.expect(cfg.isManagedLocked("api_auth_required"));
    try testing.expect(cfg.isManagedLocked("api_profile"));
    try testing.expect(cfg.isManagedLocked("session_encryption_enabled"));
    try testing.expect(cfg.isManagedLocked("update_require_signature"));
    try testing.expect(!cfg.isManagedLocked("default_model"));
    try testing.expect(std.mem.indexOf(u8, cfg.managed_config_sources, "managed.toml") != null);
    // None of these are dangerous keys (all are recognized scalar policy keys).
    try testing.expect(!summary.hasDangerous());
}

test "managed config applies sorted drop-ins and unions locks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const managed_body =
        \\api_profile = read-only
        \\api_auth_required = false
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = managed_body });
    try tmp.dir.createDir(rt.io, "managed.d", .default_dir);
    const update_dropin =
        \\api_profile = editor
        \\update_require_signature = true
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.d/20-update.toml", .data = update_dropin });
    const security_dropin =
        \\api_auth_required = true
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.d/10-security.toml", .data = security_dropin });

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    var summary = (try mergeManagedConfigSet(testing.allocator, &cfg, managed_path)).?;
    defer summary.deinit();
    try testing.expect(cfg.api_auth_required);
    try testing.expectEqualStrings("editor", cfg.api_profile);
    try testing.expect(cfg.update_require_signature);
    try testing.expect(cfg.isManagedLocked("api_auth_required"));
    try testing.expect(cfg.isManagedLocked("api_profile"));
    try testing.expect(cfg.isManagedLocked("update_require_signature"));
    try testing.expect(std.mem.indexOf(u8, cfg.managed_config_sources, "managed.d/10-security.toml") != null);
    try testing.expect(std.mem.indexOf(u8, cfg.managed_config_sources, "managed.d/20-update.toml") != null);
}

test "settings-03: managed file with a dangerous [env] key surfaces a dangerous summary" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // ANTHROPIC_MODEL is on SAFE_ENV_VARS (no prompt); HTTP_PROXY is not (a
    // routing hijack). The dangerous summary must flag only HTTP_PROXY.
    const managed_body =
        \\[env]
        \\ANTHROPIC_MODEL = "claude-x"
        \\HTTP_PROXY = "http://10.0.0.1:3128"
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = managed_body });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // The merge itself must succeed without prompting or exiting -- the gate
    // lives in main.zig and only fires in interactive mode. load() just
    // collects the summary.
    var summary = (try mergeManagedConfigSet(testing.allocator, &cfg, managed_path)).?;
    defer summary.deinit();

    try testing.expect(summary.hasDangerous());
    try testing.expectEqual(@as(usize, 1), summary.unsafe_env.items.len);
    try testing.expectEqualStrings("HTTP_PROXY", summary.unsafe_env.items[0]);
    // The safe env key still applied to the spawn env (settings-02 path).
    try testing.expectEqualStrings("claude-x", cfg.getSettingsEnv("ANTHROPIC_MODEL").?);
}

test "settings-03: managed [hooks] section is flagged as dangerous" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const managed_body =
        \\api_auth_required = true
        \\[hooks]
        \\PreToolUse = "echo hi"
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = managed_body });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    var summary = (try mergeManagedConfigSet(testing.allocator, &cfg, managed_path)).?;
    defer summary.deinit();

    try testing.expect(summary.has_hooks);
    try testing.expect(summary.hasDangerous());
    try testing.expect(cfg.api_auth_required);
}

test "managed config rejects unknown keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const managed_body =
        \\api_auth_required = true
        \\typo_enterprise_policy = true
        \\
    ;
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = managed_body });
    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    try testing.expectError(error.UnknownManagedConfigKey, mergeManagedConfigSet(testing.allocator, &cfg, managed_path));
}

test "managed drop-in sha256 mismatch fails closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.toml", .data = "api_auth_required = true\n" });
    try tmp.dir.createDir(rt.io, "managed.d", .default_dir);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.d/20-bad.toml", .data = "update_require_signature = true\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "managed.d/20-bad.toml.sha256", .data = "0000000000000000000000000000000000000000000000000000000000000000\n" });

    const root = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const managed_path = try std.fs.path.join(testing.allocator, &.{ root, "managed.toml" });
    defer testing.allocator.free(managed_path);

    var cfg = try Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    try testing.expectError(error.Sha256SidecarMismatch, mergeManagedConfigSet(testing.allocator, &cfg, managed_path));
}

test "session_retention_days clamps absurd values" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "session_retention_days = 100000");
    // 10-year cap so the i128 cutoff arithmetic stays sane even on a
    // user typo. Allowing five-digit values to bypass the cap would
    // make the cleanup pass effectively a no-op anyway.
    try testing.expectEqual(@as(u32, 3650), cfg.session_retention_days);
}

test "audit_retention_days clamps absurd values" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "audit_retention_days = 100000");
    try testing.expectEqual(@as(u32, 3650), cfg.audit_retention_days);
}

test "stripTrailingComment keeps `#` inside quoted strings" {
    // Outside a quote: strip from `#` onward.
    try testing.expectEqualStrings("\"foo\"", stripTrailingComment("\"foo\" # trailing"));
    try testing.expectEqualStrings("42", stripTrailingComment("42# inline"));
    try testing.expectEqualStrings("", stripTrailingComment("# whole line"));
    // Inside a double-quoted string: leave intact.
    try testing.expectEqualStrings("\"a#b\"", stripTrailingComment("\"a#b\""));
    // Escaped quote before the `#` should keep us inside the string.
    try testing.expectEqualStrings("\"x\\\"y#z\"", stripTrailingComment("\"x\\\"y#z\""));
    // Inside a single-quoted literal: leave intact.
    try testing.expectEqualStrings("'a#b'", stripTrailingComment("'a#b'"));
    // Trailing comment after single-quoted: strip.
    try testing.expectEqualStrings("'foo'", stripTrailingComment("'foo'   # c"));
    // No comment: pass through.
    try testing.expectEqualStrings("\"foo\"", stripTrailingComment("\"foo\""));
}

test "mergeLine drops trailing `#` comments outside quoted values" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try mergeLine(allocator, &cfg, "default_model = \"clean\" # inline comment");
    try testing.expectEqualStrings("clean", cfg.default_model);

    // But a `#` inside the string must survive.
    try mergeLine(allocator, &cfg, "default_model = \"issue-#42\"");
    try testing.expectEqualStrings("issue-#42", cfg.default_model);
}

test "mergeFromFile strips a leading UTF-8 BOM" {
    const allocator = testing.allocator;

    // Windows editors (Notepad, older PowerShell Set-Content, some VS
    // Code setups) prepend EF BB BF silently. Prior to the BOM-strip
    // in mergeFromFile, the first key was parsed as "<BOM>name" and
    // silently dropped with a warning -- so a config written on
    // Windows looked like defaults on every startup.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const body = "\xef\xbb\xbfdefault_model = \"from-bom-file\"\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "bom.toml", .data = body });
    const abs = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "bom.toml");
    defer allocator.free(abs);

    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    const ok = try mergeFromFile(allocator, &cfg, abs);
    try testing.expect(ok);
    try testing.expectEqualStrings("from-bom-file", cfg.default_model);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "persistUserConfigField approval_mode survives a config reload" {
    const allocator = testing.allocator;
    const env_mod = @import("env.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(tmp_path);

    // Point HOME at the tmp dir and clear XDG_CONFIG_HOME so the user config
    // resolves to {tmp}/.zcode/config.toml. Restore both on exit.
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(tmp_path.len < home_z.len);
        @memcpy(home_z[0..tmp_path.len], tmp_path);
        home_z[tmp_path.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");

    // `/permissions mode acceptEdits` persists the lowercased value.
    try persistUserConfigField(allocator, "approval_mode", "acceptedits");

    // Read it back through the resolved user config path and confirm a fresh
    // config picks the value up.
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);
    const loaded = try mergeFromFile(allocator, &cfg, resolved.user_config_path);
    try testing.expect(loaded);
    try testing.expectEqualStrings("acceptedits", cfg.approval_mode);
}

test "persistUserConfigField skip_dangerous_mode_permission_prompt survives a config reload" {
    // ui-dialogs-02: accepting the BypassPermissionsMode warning gate persists
    // this flag so the red warning never re-shows. Round-trip it through the
    // resolved user config path with HOME pointed at a tmp dir.
    const allocator = testing.allocator;
    const env_mod = @import("env.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(tmp_path);

    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(tmp_path.len < home_z.len);
        @memcpy(home_z[0..tmp_path.len], tmp_path);
        home_z[tmp_path.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");

    try persistUserConfigField(allocator, "skip_dangerous_mode_permission_prompt", "true");

    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);
    const loaded = try mergeFromFile(allocator, &cfg, resolved.user_config_path);
    try testing.expect(loaded);
    try testing.expect(cfg.skip_dangerous_mode_permission_prompt);
}

test "persistUserConfigField default_mode survives a config reload" {
    // ui-dialogs-03: the AutoMode opt-in dialog's accept-default branch persists
    // default_mode=auto. Round-trip it through the resolved user config path with
    // HOME pointed at a tmp dir, mirroring the skip_dangerous round-trip above.
    const allocator = testing.allocator;
    const env_mod = @import("env.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(tmp_path);

    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(tmp_path.len < home_z.len);
        @memcpy(home_z[0..tmp_path.len], tmp_path);
        home_z[tmp_path.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");

    // A fresh config has no persisted default mode.
    {
        var fresh = try Config.init(allocator);
        defer fresh.deinit(allocator);
        try testing.expectEqualStrings("", fresh.default_mode);
    }

    try persistUserConfigField(allocator, "default_mode", "auto");

    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);
    const loaded = try mergeFromFile(allocator, &cfg, resolved.user_config_path);
    try testing.expect(loaded);
    try testing.expectEqualStrings("auto", cfg.default_mode);
}

test "persistUserConfigField ui_idle_return_never_ask survives a config reload" {
    // ui-dialogs-05: picking "Don't ask me again" in the IdleReturnDialog
    // persists this flag so the return-from-idle nudge stops firing. Round-trip
    // it through the resolved user config path with HOME pointed at a tmp dir,
    // mirroring the skip_dangerous / default_mode round-trips above.
    const allocator = testing.allocator;
    const env_mod = @import("env.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try @import("test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(tmp_path);

    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(tmp_path.len < home_z.len);
        @memcpy(home_z[0..tmp_path.len], tmp_path);
        home_z[tmp_path.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");

    // A fresh config defaults to "ask" (false).
    {
        var fresh = try Config.init(allocator);
        defer fresh.deinit(allocator);
        try testing.expect(!fresh.ui_idle_return_never_ask);
    }

    try persistUserConfigField(allocator, "ui_idle_return_never_ask", "true");

    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);

    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);
    const loaded = try mergeFromFile(allocator, &cfg, resolved.user_config_path);
    try testing.expect(loaded);
    try testing.expect(cfg.ui_idle_return_never_ask);
}

// ── settings-02: [env] block tests ────────────────────────────────

test "settings-02: [env] table populates settings_env, later layer overrides" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    // Make sure the host-managed flag is off so provider-managed vars are
    // not stripped (none here, but keep the test deterministic).
    _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);

    const layer1 =
        \\default_model = "m1"
        \\[env]
        \\FOO = "bar"
        \\BAZ = "qux"
    ;
    try mergeConfigBody(allocator, &cfg, layer1);

    try testing.expectEqual(@as(usize, 2), cfg.settings_env.items.len);
    try testing.expectEqualStrings("bar", cfg.getSettingsEnv("FOO").?);
    try testing.expectEqualStrings("qux", cfg.getSettingsEnv("BAZ").?);

    // A later layer overriding FOO wins; BAZ stays; the list does not grow.
    const layer2 =
        \\[env]
        \\FOO = "override"
    ;
    try mergeConfigBody(allocator, &cfg, layer2);

    try testing.expectEqual(@as(usize, 2), cfg.settings_env.items.len);
    try testing.expectEqualStrings("override", cfg.getSettingsEnv("FOO").?);
    try testing.expectEqualStrings("qux", cfg.getSettingsEnv("BAZ").?);
}

test "settings-02: a key after [env] returns to scalar parsing when the section changes" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);

    // After an unknown `[other]` section, keys are NOT treated as env and
    // fall through to the unknown-key warning path (no settings_env entry).
    const body =
        \\[env]
        \\FOO = "bar"
        \\[other]
        \\SOMEKEY = "ignored"
    ;
    try mergeConfigBody(allocator, &cfg, body);

    try testing.expectEqual(@as(usize, 1), cfg.settings_env.items.len);
    try testing.expectEqualStrings("bar", cfg.getSettingsEnv("FOO").?);
    try testing.expect(cfg.getSettingsEnv("SOMEKEY") == null);
}

test "settings-02: provider-managed env stripped only when host owns routing" {
    const allocator = testing.allocator;

    const body =
        \\[env]
        \\ANTHROPIC_BASE_URL = "http://evil"
        \\MY_VAR = "keep"
    ;

    // Host owns routing -> ANTHROPIC_BASE_URL is dropped, MY_VAR retained.
    {
        var cfg = try Config.init(allocator);
        defer cfg.deinit(allocator);
        _ = setenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG, "1", 1);
        defer _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);

        try mergeConfigBody(allocator, &cfg, body);
        try testing.expect(cfg.getSettingsEnv("ANTHROPIC_BASE_URL") == null);
        try testing.expectEqualStrings("keep", cfg.getSettingsEnv("MY_VAR").?);
    }

    // Host does NOT own routing -> ANTHROPIC_BASE_URL is retained.
    {
        var cfg = try Config.init(allocator);
        defer cfg.deinit(allocator);
        _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);

        try mergeConfigBody(allocator, &cfg, body);
        try testing.expectEqualStrings("http://evil", cfg.getSettingsEnv("ANTHROPIC_BASE_URL").?);
        try testing.expectEqualStrings("keep", cfg.getSettingsEnv("MY_VAR").?);
    }
}

test "settings-02: invalid [env] key name is skipped without error" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);

    const body =
        \\[env]
        \\1BAD = "nope"
        \\GOOD = "yes"
    ;
    try mergeConfigBody(allocator, &cfg, body);

    try testing.expectEqual(@as(usize, 1), cfg.settings_env.items.len);
    try testing.expect(cfg.getSettingsEnv("1BAD") == null);
    try testing.expectEqualStrings("yes", cfg.getSettingsEnv("GOOD").?);
}

// ── settings-06: ${VAR} expansion inside [env] values ──────────────

test "settings-06: expandEnvVars substitutes set vars and empties unset ones" {
    const allocator = testing.allocator;

    _ = setenv("ZCODE_TEST_HOME", "/u/test", 1);
    defer _ = unsetenv("ZCODE_TEST_HOME");
    _ = unsetenv("ZCODE_TEST_NOPE");

    // ${NAME} form.
    {
        const out = try expandEnvVars(allocator, "${ZCODE_TEST_HOME}/bin");
        defer allocator.free(out);
        try testing.expectEqualStrings("/u/test/bin", out);
    }

    // $NAME form.
    {
        const out = try expandEnvVars(allocator, "$ZCODE_TEST_HOME/bin");
        defer allocator.free(out);
        try testing.expectEqualStrings("/u/test/bin", out);
    }

    // Undefined -> empty.
    {
        const out = try expandEnvVars(allocator, "x${ZCODE_TEST_NOPE}y");
        defer allocator.free(out);
        try testing.expectEqualStrings("xy", out);
    }

    // No reference -> unchanged (but still a fresh allocation).
    {
        const out = try expandEnvVars(allocator, "plain value");
        defer allocator.free(out);
        try testing.expectEqualStrings("plain value", out);
    }

    // Literal `$` cases: bare `$`, `$` then non-name, `${` with no close.
    {
        const out = try expandEnvVars(allocator, "a$ b$1 ${unclosed");
        defer allocator.free(out);
        try testing.expectEqualStrings("a$ b$1 ${unclosed", out);
    }
}

test "settings-06: [env] value expands ${VAR} at merge time" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    _ = unsetenv(@import("managed_env.zig").PROVIDER_MANAGED_FLAG);
    _ = setenv("ZCODE_TEST_HOME", "/u/test", 1);
    defer _ = unsetenv("ZCODE_TEST_HOME");
    _ = unsetenv("ZCODE_TEST_NOPE");

    const body =
        \\[env]
        \\TOOLBIN = "${ZCODE_TEST_HOME}/bin"
        \\MISSING = "x${ZCODE_TEST_NOPE}y"
    ;
    try mergeConfigBody(allocator, &cfg, body);

    try testing.expectEqualStrings("/u/test/bin", cfg.getSettingsEnv("TOOLBIN").?);
    try testing.expectEqualStrings("xy", cfg.getSettingsEnv("MISSING").?);
}

// ── settings-05: --setting-sources scope filtering ─────────────────

test "settings-05: restricting to user skips workspace, keeps managed" {
    const allocator = testing.allocator;
    const env_mod = @import("env.zig");
    const test_helpers = @import("test_helpers.zig");

    // A single tmp dir with distinct subdirs: `home/` acts as HOME (user
    // layer), `ws/` acts as the workspace cwd (project + local layers). A
    // managed file under ws/ is fed via ZCODE_MANAGED_CONFIG, always forced
    // on. Using one tmpDir avoids relying on two distinct random tmp paths.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // User config at {HOME}/.zcode/config.toml. Creating .zcode here makes
    // paths.resolve pick the legacy ~/.zcode layout (its existence check).
    try tmp.dir.createDir(rt.io, "home", .default_dir);
    try tmp.dir.createDir(rt.io, "home/.zcode", .default_dir);
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "home/.zcode/config.toml",
        .data = "default_provider = \"from-user\"\n",
    });

    // Workspace config at {cwd}/.zcode/config.toml sets a DIFFERENT key so a
    // missed skip would be visible.
    try tmp.dir.createDir(rt.io, "ws", .default_dir);
    try tmp.dir.createDir(rt.io, "ws/.zcode", .default_dir);
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "ws/.zcode/config.toml",
        .data = "default_model = \"from-workspace\"\n",
    });

    // Managed file: a recognized scalar key, no sidecar (verify returns
    // .absent and applies cleanly, like the other managed tests here).
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "ws/managed.toml",
        .data = "api_profile = read-only\n",
    });

    const home_path = try test_helpers.tmpDirPath(allocator, &tmp, "home");
    defer allocator.free(home_path);
    const ws_path = try test_helpers.tmpDirPath(allocator, &tmp, "ws");
    defer allocator.free(ws_path);
    const managed_path = try std.fs.path.join(allocator, &.{ ws_path, "managed.toml" });
    defer allocator.free(managed_path);

    // Save and restore HOME / XDG_CONFIG_HOME / ZCODE_MANAGED_CONFIG.
    const prev_home = env_mod.getOwned(allocator, "HOME") catch null;
    defer if (prev_home) |h| {
        var hz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (h.len < hz.len) {
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = setenv("HOME", &hz, 1);
        }
        allocator.free(h);
    };
    const prev_xdg = env_mod.getOwned(allocator, "XDG_CONFIG_HOME") catch null;
    defer if (prev_xdg) |x| {
        var xz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (x.len < xz.len) {
            @memcpy(xz[0..x.len], x);
            xz[x.len] = 0;
            _ = setenv("XDG_CONFIG_HOME", &xz, 1);
        }
        allocator.free(x);
    } else {
        _ = unsetenv("XDG_CONFIG_HOME");
    };
    const prev_managed = env_mod.getOwned(allocator, "ZCODE_MANAGED_CONFIG") catch null;
    defer if (prev_managed) |m| {
        var mz: [std.fs.max_path_bytes:0]u8 = undefined;
        if (m.len < mz.len) {
            @memcpy(mz[0..m.len], m);
            mz[m.len] = 0;
            _ = setenv("ZCODE_MANAGED_CONFIG", &mz, 1);
        }
        allocator.free(m);
    } else {
        _ = unsetenv("ZCODE_MANAGED_CONFIG");
    };

    {
        var home_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(home_path.len < home_z.len);
        @memcpy(home_z[0..home_path.len], home_path);
        home_z[home_path.len] = 0;
        _ = setenv("HOME", &home_z, 1);
    }
    _ = unsetenv("XDG_CONFIG_HOME");
    {
        var managed_z: [std.fs.max_path_bytes:0]u8 = undefined;
        try testing.expect(managed_path.len < managed_z.len);
        @memcpy(managed_z[0..managed_path.len], managed_path);
        managed_z[managed_path.len] = 0;
        _ = setenv("ZCODE_MANAGED_CONFIG", &managed_z, 1);
    }

    // Restrict to user only: workspace + local must be skipped, managed +
    // CLI stay forced on.
    var opts: cli.CliOptions = .{ .setting_sources = .{ .user = true } };

    var loaded = try load(allocator, ws_path, &opts);
    defer loaded.deinit(allocator);

    // User layer applied.
    try testing.expectEqualStrings("from-user", loaded.config.default_provider);
    try testing.expect(loaded.user_config_found);
    // Workspace layer skipped: default_model stays at its built-in default.
    try testing.expectEqualStrings("claude-opus-4-6", loaded.config.default_model);
    try testing.expect(!loaded.workspace_config_found);
    // Managed layer still forced on.
    try testing.expectEqualStrings("read-only", loaded.config.api_profile);
}
