const std = @import("std");
const std_io = @import("std_io.zig");
const cli = @import("../cli/args.zig");
const paths = @import("paths.zig");
const config_parse = @import("config_parse.zig");
const ui_theme = @import("ui_theme.zig");
const managed_security = @import("managed_security.zig");

// Re-export parsing entry points so callers do not need to change.
pub const load = config_parse.load;
pub const resolveWorkingDirectory = config_parse.resolveWorkingDirectory;

/// A single settings-sourced environment variable (settings-02). Both
/// `name` and `value` are owned by `Config`; freed in `Config.deinit`.
pub const EnvPair = struct {
    name: []u8,
    value: []u8,
};

pub const Config = struct {
    default_provider: []u8,
    default_model: []u8,
    available_models: []u8,
    fallback_provider: []u8,
    fallback_model: []u8,
    /// Small/fast model used for cheap secondary passes (e.g. the WebFetch
    /// `prompt`-summarization pass). When the active provider is Anthropic the
    /// summarizer uses this model; for other providers it falls back to the
    /// active model so the call still works. Default "claude-haiku-4-5".
    small_fast_model: []u8,
    provider_api_key: []u8,
    provider_base_url: []u8,
    local_base_url: []u8,
    fallback_provider_api_key: []u8,
    fallback_provider_base_url: []u8,
    provider_timeout_ms: u32,
    provider_retry_count: u8,
    profile: []u8,
    approval_mode: []u8,
    sandbox: []u8,
    interactive_streaming: bool,
    intent_reprompt_enabled: bool,
    ui_fullscreen: bool,
    ui_alt_screen: bool,
    ui_spinner: bool,
    ui_thinking_summary: bool,
    ui_brief_mode: bool,
    ui_vim_mode: bool,
    ui_auto_mode_opt_in_seen: bool,
    /// ui-dialogs-03: persisted default permission mode chosen via the AutoMode
    /// opt-in dialog's "Yes, and make it my default mode" branch. Mirrors the
    /// reference's `permissions.defaultMode` user setting. Empty string means
    /// "no persisted default-mode override". Set to "auto" by accept-default.
    default_mode: []u8,
    /// ui-dialogs-02: once the user accepts the bypass-permissions warning gate,
    /// this is persisted so the red warning is never shown again. Mirrors the
    /// reference's `skipDangerousModePermissionPrompt` user setting.
    skip_dangerous_mode_permission_prompt: bool,
    /// ui-dialogs-05: once the user picks "Don't ask me again" in the
    /// IdleReturnDialog, this is persisted so the return-from-idle nudge is
    /// never shown again. Mirrors the reference's `never` action.
    ui_idle_return_never_ask: bool,
    ui_density: []u8,
    ui_leader_key: []u8,
    ui_show_top_bar: bool,
    ui_show_shortcuts_panel: bool,
    ui_prompt_label: []u8,
    ui_transcript_max_lines: usize,
    ui_show_scroll_hint: bool,
    ui_bottom_margin_rows: usize,
    ui_line_spacing: usize,
    ui_color_enabled: bool,
    ui_theme: []u8,
    ui_highlight_links: bool,
    ui_highlight_paths: bool,
    ui_color_lists: bool,
    ui_highlight_code_blocks: bool,
    ui_status_show_workspace: bool,
    ui_status_show_model: bool,
    ui_status_show_safety: bool,
    ui_status_show_tokens: bool,
    ui_status_show_hint: bool,
    control_plane_url: []u8,
    control_plane_token: []u8,
    control_plane_policy_sync: bool,
    control_plane_policy_verify_hash: bool,
    control_plane_managed_settings_sync: bool,
    control_plane_managed_settings_verify_hash: bool,
    cloud_telemetry_opt_in: bool,
    egress_allowlist: []u8,
    /// Comma-separated explicit deny list of hosts, same entry syntax as
    /// `egress_allowlist` (bare host or "*.example.com"). Hosts matching
    /// any entry are denied REGARDLESS of the allowlist (deny wins).
    egress_denylist: []u8,
    egress_allow_private_network_plaintext: bool,
    /// Sandbox network knobs ported from the reference sandbox config
    /// (network.allowUnixSockets / httpProxyPort / socksProxyPort).
    /// These are CONFIG-ONLY PLACEHOLDERS in this phase: they are parsed
    /// and validated but NOT enforced. Binding to an HTTP/SOCKS proxy
    /// and allowing unix sockets in the shell sandbox backend is a
    /// sandbox-runtime feature deferred to a later phase. Do not treat
    /// these as active controls.
    egress_allow_unix_sockets: bool,
    /// 0 means unset/disabled. Placeholder only (see above).
    egress_http_proxy_port: u16,
    /// 0 means unset/disabled. Placeholder only (see above).
    egress_socks_proxy_port: u16,
    model_context_window: usize,
    reserved_output_tokens: usize,
    reserved_reasoning_tokens: usize,
    instruction_file_cap_bytes: usize,
    instruction_total_cap_bytes: usize,
    instruction_imports_enabled: bool,
    instruction_import_max_depth: u8,
    prompt_cache_hints_enabled: bool,
    feature_kill_switches: []u8,
    /// Preferred terminal-notification channel for long-turn completion
    /// notifications. One of: "auto", "iterm2", "iterm2_with_bell", "kitty",
    /// "ghostty", "terminal_bell", "notifications_disabled". Default "auto"
    /// preserves the current auto-detect behavior. Resolved at the notify
    /// call site via notifier.channelFromConfig.
    preferred_notif_channel: []u8,
    output_style: []u8,
    append_system_prompt: []u8,
    max_history_turns: usize,
    /// Time-based (cache-staleness) microcompaction (compaction-10). When
    /// enabled, an aggressive tool-result clear fires once the gap since the
    /// last assistant turn crosses `time_based_mc_gap_minutes` (the server
    /// prompt-cache TTL). Default-off to match the reference's experimental
    /// gating; the per-turn age-based microcompact runs regardless.
    time_based_mc_enabled: bool = false,
    /// Gap (minutes) since the last assistant turn before the time-based
    /// microcompaction fires. 60 matches the server's 1h cache TTL.
    time_based_mc_gap_minutes: usize = 60,
    max_tool_rounds: usize,
    /// Phase 22 (agent-loop-deep-11): per-turn USD budget ceiling. 0 (the
    /// default) disables the cap. When > 0, an agentic turn stops once its
    /// cumulative estimated spend reaches this dollar amount, with the
    /// TurnResult reporting `terminal_reason == .max_budget_usd`. Defaulted so
    /// the explicit init in `defaultConfig` need not list it.
    max_budget_usd: f64 = 0,
    /// Phase 22 (agent-loop-deep-11): cap on schema-invalid structured-output
    /// retries within a single turn. Matches the reference's
    /// MAX_STRUCTURED_OUTPUT_RETRIES default of 5. When a response schema is
    /// active and the model keeps producing output that fails validation, the
    /// turn stops after this many retries with
    /// `terminal_reason == .max_structured_output_retries`.
    max_structured_output_retries: u32 = 5,
    tool_output_artifact_threshold_bytes: usize,
    mcp_tool_bridge_enabled: bool,
    browser_bridge_enabled: bool,
    browser_bridge_port: u16,
    api_profile: []u8,
    api_role: []u8,
    api_auth_required: bool,
    api_bearer_token: []u8,
    api_oidc_issuer: []u8,
    api_oidc_audience: []u8,
    api_oidc_hs256_secret: []u8,
    api_oidc_jwks_json: []u8,
    api_oidc_jwks_file: []u8,
    api_oidc_jwks_url: []u8,
    api_oidc_jwks_cache_ttl_seconds: u32,
    update_require_signature: bool,
    update_pinned_version: []u8,
    managed_locked_keys: []u8,
    managed_config_sources: []u8,
    session_encryption_enabled: bool,
    /// Days to keep session JSONL files in the sessions dir before
    /// the startup cleanup pass deletes them. 0 disables the pass
    /// entirely (default), so the storage primitive is opt-in.
    /// Matches claude-code-main's DEFAULT_CLEANUP_PERIOD_DAYS = 30
    /// in spirit but we keep it off until the user sets it so we
    /// never silently delete sessions a user thought they could
    /// resume.
    session_retention_days: u32,
    /// Days to keep HMAC-chained audit JSONL files. 0 disables audit
    /// cleanup. Defaults to 90 days for enterprise evidence retention.
    audit_retention_days: u32,
    preprocessor_enabled: bool,
    preprocessor_provider: []u8,
    preprocessor_model: []u8,
    preprocessor_base_url: []u8,
    preprocessor_max_output_tokens: usize,
    preprocessor_api_key: []u8,
    /// BCP 47 language tag or plain language name ("fr", "ja",
    /// "Spanish", "Brazilian Portuguese") the user wants the
    /// model to respond in. Empty = English / no override.
    /// Ported from claude-code-main/src/constants/prompts.ts
    /// getLanguageSection -- the prompt engine injects a
    /// "Always respond in <lang>" block so the user doesn't
    /// have to repeat the instruction at the top of every turn.
    preferred_language: []u8,

    /// When true, the audit log and OTel exporter strip prompt and
    /// response bodies before writing, keeping only metadata like
    /// tool name, latency, and token counts. Intended for enterprise
    /// environments where prompt contents may contain customer data
    /// that must not be shipped off-host. Secrets are always redacted
    /// regardless of this flag; this widens the redaction to cover
    /// prompt bodies as a class.
    privacy_redact_prompt_bodies: bool,

    /// Per-attribute telemetry INCLUDE allowlist (analytics-10). null =
    /// default behaviour: emit every telemetry attribute. When set, only
    /// attributes whose key appears in this list are emitted; all others are
    /// dropped before the record is serialized. Mirrors claude-code-main's
    /// telemetryAttributes.ts per-attribute OTEL_METRICS_INCLUDE_* toggles,
    /// generalized to an explicit key allowlist. The backing slices are not
    /// owned by Config (deinit does not free them); a future config loader
    /// that allocates them owns their lifetime.
    telemetry_attribute_allowlist: ?[]const []const u8 = null,

    /// Per-attribute cardinality cap (analytics-10). null = unlimited. When
    /// set to N, only the first N distinct values of any single attribute key
    /// are emitted verbatim; the (N+1)-th and later distinct values are
    /// collapsed to the literal "<other>" so a hostile or high-cardinality
    /// stream cannot blow up the distinct-value space on the collector. The
    /// limit itself is the memory bound on the per-key value set.
    telemetry_cardinality_limit: ?usize = null,

    /// Tri-state auto-memory gate (memory-10). null = unset (default ON
    /// downstream), false = user opted out, true = user opted in. Mirrors
    /// claude-code-main settings.autoMemoryEnabled (paths.ts:50-53): an
    /// explicit setting wins over the default, but env overrides win over
    /// the setting (see core/memory_gate.zig isAutoMemoryEnabled). Optional
    /// so the gate can tell "user said false" apart from "user said nothing".
    auto_memory_enabled: ?bool = null,
    /// Trusted-source override for the auto-memory directory (memory-10).
    /// Empty = compute the default ~/.zcode/memory. Supports ~/ expansion
    /// and is validated by memory_gate.validateMemoryPath before use.
    /// Mirrors settings.autoMemoryDirectory (paths.ts:179-186).
    auto_memory_directory: []u8,

    /// Tri-state auto-dream gate (background-svc-04). null = unset (default
    /// ON downstream, preserving zcode's always-on behaviour), false = user
    /// opted out, true = user opted in. Mirrors claude-code-main
    /// settings.autoDreamEnabled (config.ts:13-21): an explicit setting wins
    /// over the GrowthBook flag default. zcode has no GrowthBook, so the only
    /// inputs are this setting (off-switch) and the always-on default.
    /// Gated together with auto_memory_enabled by dream.isGateOpen.
    auto_dream_enabled: ?bool = null,
    /// Minimum wall-clock hours between automatic dream consolidation runs.
    /// 0 (or an absurd value) is treated as the default (24) by
    /// dream.minHours, matching the reference's defensive clamp
    /// (config.ts:73-93). Mirrors the GrowthBook `minHours`.
    auto_dream_min_hours: u32,
    /// Minimum sessions touched since the last consolidation before a dream is
    /// triggered. 0 (or an absurd value) is treated as the default (5) by
    /// dream.minSessions. Mirrors the GrowthBook `minSessions`.
    auto_dream_min_sessions: u32,

    /// Whether the working spinner shows a rotating usage tip while the agent
    /// works (styles-onboarding-07). Default true matches the reference's
    /// `spinnerTipsEnabled` default. When false, no spinner tip is selected or
    /// recorded (tips.getTipToShowOnSpinner short-circuits to null).
    spinner_tips_enabled: bool,
    /// Custom spinner tips supplied by the user (the reference's
    /// `spinnerTipsOverride.tips`). zcode's config is key=value, not JSON, so
    /// the list is delimited: split on newlines first, then on ';' so a
    /// single-line value works too. Each non-empty entry becomes an
    /// always-relevant, cooldown-0 tip. Empty = no custom tips.
    spinner_tips_custom: []u8,
    /// When true, the built-in tip registry is suppressed and only the custom
    /// tips are eligible on the spinner (the reference's
    /// `spinnerTipsOverride.excludeDefault`). Default false keeps the built-in
    /// tips in the rotation alongside any custom tips.
    spinner_tips_exclude_default: bool,

    /// Persisted reasoning-effort level (commands-sweep-08). One of
    /// "auto"/"low"/"medium"/"high"/"max". Mirrors the reference's
    /// userSettings.effortLevel, persisted by `/effort <level>` via
    /// config_parse.persistUserConfigField and read back on startup by
    /// core/effort_level.zig (env CLAUDE_CODE_EFFORT_LEVEL still wins over this).
    /// "auto" means "no persisted override" (the reference clears the setting on
    /// /effort auto); the runtime then falls through to the provider/model
    /// default. Default "auto".
    reasoning_effort: []u8,

    /// Settings-sourced environment variables from a `[env]` table in any
    /// config layer (settings-02). Applied to spawned tools (shell, grep)
    /// with the same precedence as the rest of config: a later layer
    /// overriding `FOO` replaces the earlier value in place. Session vars
    /// (`/env set`) still win over these at spawn time. This is its own
    /// owned list (NOT a generic map field) so ownership cannot desync on
    /// realloc; each pair's `name`/`value` are freed in `deinit`. Empty by
    /// default. Mirrors EnvironmentVariablesSchema on the reference's
    /// user/project/policy settings (types.ts:333-335).
    settings_env: std.array_list.Managed(EnvPair),

    pub fn init(allocator: std.mem.Allocator) !Config {
        return .{
            .default_provider = try allocator.dupe(u8, "anthropic"),
            .default_model = try allocator.dupe(u8, "claude-opus-4-6"),
            .available_models = try allocator.dupe(u8, ""),
            .fallback_provider = try allocator.dupe(u8, ""),
            .fallback_model = try allocator.dupe(u8, ""),
            .small_fast_model = try allocator.dupe(u8, "claude-haiku-4-5"),
            .provider_api_key = try allocator.dupe(u8, ""),
            .provider_base_url = try allocator.dupe(u8, ""),
            .local_base_url = try allocator.dupe(u8, "http://127.0.0.1:11434"),
            .fallback_provider_api_key = try allocator.dupe(u8, ""),
            .fallback_provider_base_url = try allocator.dupe(u8, ""),
            .provider_timeout_ms = 60_000,
            .provider_retry_count = 2,
            .profile = try allocator.dupe(u8, "default"),
            .approval_mode = try allocator.dupe(u8, "tiered-auto"),
            .sandbox = try allocator.dupe(u8, "workspace-write"),
            .interactive_streaming = true,
            .intent_reprompt_enabled = true,
            .ui_fullscreen = true,
            .ui_alt_screen = true,
            .ui_spinner = true,
            .ui_thinking_summary = true,
            .ui_brief_mode = false,
            .ui_vim_mode = false,
            .ui_auto_mode_opt_in_seen = false,
            .default_mode = try allocator.dupe(u8, ""),
            .skip_dangerous_mode_permission_prompt = false,
            .ui_idle_return_never_ask = false,
            .ui_density = try allocator.dupe(u8, "full"),
            .ui_leader_key = try allocator.dupe(u8, "ctrl+x"),
            .ui_show_top_bar = true,
            .ui_show_shortcuts_panel = true,
            .ui_prompt_label = try allocator.dupe(u8, ">"),
            .ui_transcript_max_lines = 20_000,
            .ui_show_scroll_hint = true,
            .ui_bottom_margin_rows = 2,
            .ui_line_spacing = 1,
            .ui_color_enabled = true,
            .ui_theme = try allocator.dupe(u8, "dark"),
            .ui_highlight_links = true,
            .ui_highlight_paths = true,
            .ui_color_lists = true,
            .ui_highlight_code_blocks = true,
            .ui_status_show_workspace = true,
            .ui_status_show_model = true,
            .ui_status_show_safety = true,
            .ui_status_show_tokens = true,
            .ui_status_show_hint = true,
            .control_plane_url = try allocator.dupe(u8, ""),
            .control_plane_token = try allocator.dupe(u8, ""),
            .control_plane_policy_sync = false,
            .control_plane_policy_verify_hash = true,
            .control_plane_managed_settings_sync = false,
            .control_plane_managed_settings_verify_hash = true,
            .cloud_telemetry_opt_in = false,
            .egress_allowlist = try allocator.dupe(u8, ""),
            .egress_denylist = try allocator.dupe(u8, ""),
            .egress_allow_private_network_plaintext = false,
            .egress_allow_unix_sockets = false,
            .egress_http_proxy_port = 0,
            .egress_socks_proxy_port = 0,
            .model_context_window = 200_000,
            .reserved_output_tokens = 16_384,
            .reserved_reasoning_tokens = 2_048,
            .instruction_file_cap_bytes = 65_536,
            .instruction_total_cap_bytes = 262_144,
            .instruction_imports_enabled = true,
            .instruction_import_max_depth = 5,
            .prompt_cache_hints_enabled = true,
            .feature_kill_switches = try allocator.dupe(u8, ""),
            .preferred_notif_channel = try allocator.dupe(u8, "auto"),
            .output_style = try allocator.dupe(u8, "default"),
            .append_system_prompt = try allocator.dupe(u8, ""),
            .max_history_turns = 24,
            .max_tool_rounds = 30,
            .tool_output_artifact_threshold_bytes = @import("tool_artifacts.zig").DEFAULT_THRESHOLD_BYTES,
            .mcp_tool_bridge_enabled = true,
            .browser_bridge_enabled = false,
            .browser_bridge_port = 9333,
            .api_profile = try allocator.dupe(u8, ""),
            .api_role = try allocator.dupe(u8, ""),
            .api_auth_required = false,
            .api_bearer_token = try allocator.dupe(u8, ""),
            .api_oidc_issuer = try allocator.dupe(u8, ""),
            .api_oidc_audience = try allocator.dupe(u8, ""),
            .api_oidc_hs256_secret = try allocator.dupe(u8, ""),
            .api_oidc_jwks_json = try allocator.dupe(u8, ""),
            .api_oidc_jwks_file = try allocator.dupe(u8, ""),
            .api_oidc_jwks_url = try allocator.dupe(u8, ""),
            .api_oidc_jwks_cache_ttl_seconds = 3600,
            .update_require_signature = false,
            .update_pinned_version = try allocator.dupe(u8, ""),
            .managed_locked_keys = try allocator.dupe(u8, ""),
            .managed_config_sources = try allocator.dupe(u8, ""),
            .session_encryption_enabled = true,
            .session_retention_days = 0,
            .audit_retention_days = 90,
            .preprocessor_enabled = false,
            .preprocessor_provider = try allocator.dupe(u8, ""),
            .preprocessor_model = try allocator.dupe(u8, ""),
            .preprocessor_base_url = try allocator.dupe(u8, ""),
            .preprocessor_max_output_tokens = 300,
            .preprocessor_api_key = try allocator.dupe(u8, ""),
            .preferred_language = try allocator.dupe(u8, ""),
            .privacy_redact_prompt_bodies = false,
            .auto_memory_enabled = null,
            .auto_memory_directory = try allocator.dupe(u8, ""),
            .auto_dream_enabled = null,
            .auto_dream_min_hours = 24,
            .auto_dream_min_sessions = 5,
            .spinner_tips_enabled = true,
            .spinner_tips_custom = try allocator.dupe(u8, ""),
            .spinner_tips_exclude_default = false,
            .reasoning_effort = try allocator.dupe(u8, "auto"),
            .settings_env = std.array_list.Managed(EnvPair).init(allocator),
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.default_provider);
        allocator.free(self.default_model);
        allocator.free(self.available_models);
        allocator.free(self.fallback_provider);
        allocator.free(self.fallback_model);
        allocator.free(self.small_fast_model);
        allocator.free(self.provider_api_key);
        allocator.free(self.provider_base_url);
        allocator.free(self.local_base_url);
        allocator.free(self.fallback_provider_api_key);
        allocator.free(self.fallback_provider_base_url);
        allocator.free(self.profile);
        allocator.free(self.approval_mode);
        allocator.free(self.default_mode);
        allocator.free(self.sandbox);
        allocator.free(self.ui_density);
        allocator.free(self.ui_leader_key);
        allocator.free(self.ui_prompt_label);
        allocator.free(self.ui_theme);
        allocator.free(self.output_style);
        allocator.free(self.preferred_notif_channel);
        allocator.free(self.feature_kill_switches);
        allocator.free(self.append_system_prompt);
        allocator.free(self.control_plane_url);
        allocator.free(self.control_plane_token);
        allocator.free(self.egress_allowlist);
        allocator.free(self.egress_denylist);
        allocator.free(self.preprocessor_provider);
        allocator.free(self.preprocessor_model);
        allocator.free(self.preprocessor_base_url);
        allocator.free(self.preprocessor_api_key);
        allocator.free(self.preferred_language);
        allocator.free(self.api_profile);
        allocator.free(self.api_role);
        allocator.free(self.api_bearer_token);
        allocator.free(self.api_oidc_issuer);
        allocator.free(self.api_oidc_audience);
        allocator.free(self.api_oidc_hs256_secret);
        allocator.free(self.api_oidc_jwks_json);
        allocator.free(self.api_oidc_jwks_file);
        allocator.free(self.api_oidc_jwks_url);
        allocator.free(self.update_pinned_version);
        allocator.free(self.managed_locked_keys);
        allocator.free(self.managed_config_sources);
        allocator.free(self.auto_memory_directory);
        allocator.free(self.spinner_tips_custom);
        allocator.free(self.reasoning_effort);
        for (self.settings_env.items) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        self.settings_env.deinit();
    }

    /// Upsert a settings-sourced env var (settings-02). A later config layer
    /// overriding an existing `name` replaces its value in place (matching the
    /// scalar-key precedence: managed wins over local wins over user). New
    /// names append. Both slices are duped into `Config`'s allocator. OOM-safe
    /// ordering on replace: dupe the new value first, then free the old one,
    /// so an allocation failure leaves the old entry intact.
    pub fn upsertSettingsEnv(self: *Config, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        for (self.settings_env.items) |*pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                const next = try allocator.dupe(u8, value);
                allocator.free(pair.value);
                pair.value = next;
                return;
            }
        }
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);
        try self.settings_env.append(.{ .name = name_copy, .value = value_copy });
    }

    /// Look up a settings-sourced env var value by name. Returns null when
    /// unset. Borrowed slice owned by `Config`.
    pub fn getSettingsEnv(self: *const Config, name: []const u8) ?[]const u8 {
        for (self.settings_env.items) |pair| {
            if (std.mem.eql(u8, pair.name, name)) return pair.value;
        }
        return null;
    }

    pub fn validate(self: *const Config) !void {
        if (self.default_provider.len == 0) return error.InvalidProvider;
        if (self.default_model.len == 0) return error.InvalidModel;
        if (self.model_context_window == 0) return error.InvalidModelContextWindow;
        if (self.reserved_output_tokens > self.model_context_window) return error.InvalidReservedOutput;
        if (self.reserved_reasoning_tokens > self.model_context_window) return error.InvalidReservedReasoning;
        if (self.reserved_output_tokens + self.reserved_reasoning_tokens > self.model_context_window) return error.InvalidReservedOutput;
        if (self.max_history_turns == 0) return error.InvalidMaxHistoryTurns;
        if (self.max_tool_rounds == 0) return error.InvalidMaxToolRounds;
        if (self.instruction_file_cap_bytes == 0) return error.InvalidInstructionFileCap;
        if (self.provider_timeout_ms == 0) return error.InvalidProviderTimeout;
        if (self.provider_retry_count == 0) return error.InvalidProviderRetryCount;
        if (!isKnownUiDensity(self.ui_density)) return error.InvalidUiDensity;
        if (self.ui_leader_key.len == 0) return error.InvalidLeaderKey;
        if (self.ui_prompt_label.len == 0) return error.InvalidPromptLabel;
        if (ui_theme.parseThemeSetting(self.ui_theme) == null) return error.InvalidTheme;
        if (self.output_style.len == 0) return error.InvalidOutputStyle;
        if (self.instruction_total_cap_bytes == 0 or self.instruction_total_cap_bytes < self.instruction_file_cap_bytes) {
            return error.InvalidInstructionTotalCap;
        }
        if (self.instruction_import_max_depth == 0) return error.InvalidInstructionImportDepth;
        if (self.control_plane_policy_sync and self.control_plane_url.len == 0) {
            return error.InvalidControlPlaneUrl;
        }
        if (self.control_plane_managed_settings_sync and self.control_plane_url.len == 0) {
            return error.InvalidControlPlaneUrl;
        }
        if (!isValidEgressAllowlist(self.egress_allowlist)) return error.InvalidEgressAllowlist;
        // The deny list shares the allowlist entry syntax (bare host or
        // "*.example.com"); reuse the same validator.
        if (!isValidEgressAllowlist(self.egress_denylist)) return error.InvalidEgressDenylist;
        if (self.api_profile.len > 0 and !isKnownApiProfile(self.api_profile)) return error.InvalidApiProfile;
        if (self.api_role.len > 0 and !isKnownApiRole(self.api_role)) return error.InvalidApiRole;
        const api_oidc_any =
            self.api_oidc_issuer.len > 0 or
            self.api_oidc_audience.len > 0 or
            self.api_oidc_hs256_secret.len > 0 or
            self.api_oidc_jwks_json.len > 0 or
            self.api_oidc_jwks_file.len > 0 or
            self.api_oidc_jwks_url.len > 0;
        const api_oidc_complete =
            self.api_oidc_issuer.len > 0 and
            self.api_oidc_audience.len > 0 and
            (self.api_oidc_hs256_secret.len > 0 or
                self.api_oidc_jwks_json.len > 0 or
                self.api_oidc_jwks_file.len > 0 or
                self.api_oidc_jwks_url.len > 0);
        if (api_oidc_any and !api_oidc_complete) return error.InvalidApiOidcConfig;
        if (self.api_oidc_jwks_url.len > 0 and !isValidSecureOrLoopbackUrl(self.api_oidc_jwks_url)) {
            return error.InvalidApiOidcConfig;
        }
        if (self.api_auth_required and self.api_bearer_token.len == 0 and !api_oidc_complete) {
            return error.InvalidApiAuthConfig;
        }
        if (self.preprocessor_enabled) {
            if (self.preprocessor_provider.len == 0) return error.InvalidPreprocessorProvider;
            if (self.preprocessor_model.len == 0) return error.InvalidPreprocessorModel;
            // Previously only checked non-empty. A typo like
            // `--preprocessor --preprocessor-provider ollma` (should
            // be "ollama") silently fell through to runtime where
            // the preprocessor warn-logged "UnsupportedProvider" and
            // continued WITHOUT the user's explicitly-requested
            // feature. Catch unknown provider names up front.
            if (!isKnownProvider(self.preprocessor_provider)) return error.InvalidPreprocessorProvider;
        }

        // Provider name validation.
        if (!isKnownProvider(self.default_provider)) return error.InvalidProvider;

        // Sandbox profile validation.
        if (self.sandbox.len > 0 and !isKnownSandboxProfile(self.sandbox)) return error.InvalidSandboxProfile;

        // Approval mode validation.
        if (self.approval_mode.len > 0 and !isKnownApprovalMode(self.approval_mode)) return error.InvalidApprovalMode;

        // Range warnings (soft validation - log but do not block).
        if (self.provider_timeout_ms < 5_000) {
            std.log.warn("config: provider_timeout_ms ({d}) is very low, consider >= 5000", .{self.provider_timeout_ms});
        }
        if (self.provider_timeout_ms > 300_000) {
            std.log.warn("config: provider_timeout_ms ({d}) is very high, consider <= 300000", .{self.provider_timeout_ms});
        }
        if (self.provider_retry_count > 10) {
            std.log.warn("config: provider_retry_count ({d}) is very high, consider <= 10", .{self.provider_retry_count});
        }
    }

    fn isKnownProvider(name: []const u8) bool {
        const known = [_][]const u8{
            "openai",            "anthropic", "gemini",       "deepseek", "groq",
            "openrouter",        "azure",     "azure-openai", "local",    "ollama",
            "openai-compatible", "mock",
        };
        for (known) |k| {
            if (std.mem.eql(u8, name, k)) return true;
        }
        return false;
    }

    fn isKnownSandboxProfile(name: []const u8) bool {
        const known = [_][]const u8{
            "workspace-write", "read-only", "no-network", "danger-full-access", "none",
        };
        for (known) |k| {
            // Case-insensitive: accept `DANGER-FULL-ACCESS` from a
            // user who copy-pasted from a shell transcript that
            // upcased it. Downstream consumers compare against the
            // canonical lowercase form, so applyCliOverrides /
            // merge path normalizes on assignment via normalizeAscii.
            if (std.ascii.eqlIgnoreCase(name, k)) return true;
        }
        return false;
    }

    fn isKnownApprovalMode(name: []const u8) bool {
        const known = [_][]const u8{ "tiered-auto", "manual", "strict" };
        for (known) |k| {
            if (std.ascii.eqlIgnoreCase(name, k)) return true;
        }
        return false;
    }

    fn isKnownUiDensity(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "full") or std.ascii.eqlIgnoreCase(name, "clean");
    }

    fn isKnownApiProfile(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "read-only") or
            std.ascii.eqlIgnoreCase(name, "readonly") or
            std.ascii.eqlIgnoreCase(name, "editor") or
            std.ascii.eqlIgnoreCase(name, "full");
    }

    fn isKnownApiRole(name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(name, "none") or
            std.ascii.eqlIgnoreCase(name, "viewer") or
            std.ascii.eqlIgnoreCase(name, "auditor") or
            std.ascii.eqlIgnoreCase(name, "editor") or
            std.ascii.eqlIgnoreCase(name, "owner");
    }

    fn isValidEgressAllowlist(value: []const u8) bool {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |raw_entry| {
            const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
            if (entry.len == 0) continue;
            if (std.mem.indexOf(u8, entry, "://") != null) return false;
            if (std.mem.indexOfScalar(u8, entry, '/') != null) return false;
            if (std.mem.eql(u8, entry, "*.")) return false;
        }
        return true;
    }

    fn isValidSecureOrLoopbackUrl(value: []const u8) bool {
        if (std.ascii.startsWithIgnoreCase(value, "https://")) return true;
        if (!std.ascii.startsWithIgnoreCase(value, "http://")) return false;
        const rest = value["http://".len..];
        const host = if (std.mem.startsWith(u8, rest, "["))
            rest[0 .. (std.mem.indexOfScalar(u8, rest, ']') orelse return false) + 1]
        else
            rest[0..(std.mem.indexOfAny(u8, rest, ":/") orelse rest.len)];
        return std.ascii.eqlIgnoreCase(host, "localhost") or
            std.mem.eql(u8, host, "127.0.0.1") or
            std.mem.eql(u8, host, "[::1]");
    }

    pub fn isManagedLocked(self: *const Config, key: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.managed_locked_keys, ',');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.eql(u8, entry, key)) return true;
        }
        return false;
    }

    pub fn setOwnedString(_: *Config, allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
        const next = try allocator.dupe(u8, value);
        allocator.free(target.*);
        target.* = next;
    }

    /// Render all config fields as a formatted text dump for `/config`.
    /// Groups fields by prefix (provider, ui, etc.) with one field per
    /// line in `key = value` format. Sensitive fields (api_key, token)
    /// are masked. Caller owns the returned slice.
    pub fn renderAll(self: *const Config, allocator: std.mem.Allocator) ![]u8 {
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        const w = out.writer();

        const groups = [_]struct { label: []const u8, prefix: []const u8 }{
            .{ .label = "Provider", .prefix = "default_" },
            .{ .label = "Provider", .prefix = "provider_" },
            .{ .label = "Provider", .prefix = "fallback_" },
            .{ .label = "Provider", .prefix = "local_" },
            .{ .label = "Model", .prefix = "model_" },
            .{ .label = "Model", .prefix = "reserved_" },
            .{ .label = "Model", .prefix = "available_" },
            .{ .label = "UI", .prefix = "ui_" },
            .{ .label = "Approval", .prefix = "approval_" },
            .{ .label = "Approval", .prefix = "sandbox" },
            .{ .label = "Session", .prefix = "session_" },
            .{ .label = "Session", .prefix = "audit_" },
            .{ .label = "Session", .prefix = "max_" },
            .{ .label = "Instructions", .prefix = "instruction_" },
            .{ .label = "Instructions", .prefix = "prompt_cache" },
            .{ .label = "Preprocessor", .prefix = "preprocessor_" },
            .{ .label = "Advanced", .prefix = "control_plane_" },
            .{ .label = "Advanced", .prefix = "cloud_" },
            .{ .label = "Advanced", .prefix = "egress_" },
            .{ .label = "Update", .prefix = "update_" },
            .{ .label = "API", .prefix = "api_" },
            .{ .label = "Advanced", .prefix = "mcp_" },
            .{ .label = "Advanced", .prefix = "browser_" },
        };

        var last_group: []const u8 = "";
        for (groups) |group| {
            inline for (@typeInfo(Config).@"struct".fields) |field| {
                if (std.mem.startsWith(u8, field.name, group.prefix)) {
                    if (!std.mem.eql(u8, last_group, group.label)) {
                        if (last_group.len > 0) try w.writeByte('\n');
                        try w.print("# {s}\n", .{group.label});
                        last_group = group.label;
                    }
                    try writeFieldLine(w, self, field.name, field.type);
                }
            }
        }

        // Catch fields not matched by any group prefix
        inline for (@typeInfo(Config).@"struct".fields) |field| {
            var matched = false;
            for (groups) |group| {
                if (std.mem.startsWith(u8, field.name, group.prefix)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try writeFieldLine(w, self, field.name, field.type);
            }
        }

        return out.toOwnedSlice();
    }

    fn writeFieldLine(w: anytype, self: *const Config, comptime name: []const u8, comptime T: type) !void {
        const is_sensitive = std.mem.indexOf(u8, name, "api_key") != null or
            std.mem.indexOf(u8, name, "token") != null or
            std.mem.indexOf(u8, name, "secret") != null;
        if (T == []u8) {
            const val = @field(self, name);
            if (is_sensitive and val.len > 0) {
                try w.print("  {s} = ***\n", .{name});
            } else {
                try w.print("  {s} = {s}\n", .{ name, if (val.len == 0) "(empty)" else val });
            }
        } else if (T == bool) {
            try w.print("  {s} = {}\n", .{ name, @field(self, name) });
        } else if (T == u8 or T == u16 or T == u32 or T == usize) {
            try w.print("  {s} = {d}\n", .{ name, @field(self, name) });
        }
    }

    /// Look up a single config field by name and return its value as a string.
    /// Returns null if the field name is not recognized.
    pub fn getFieldValue(self: *const Config, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                const is_sensitive = std.mem.indexOf(u8, field.name, "api_key") != null or
                    std.mem.indexOf(u8, field.name, "token") != null or
                    std.mem.indexOf(u8, field.name, "secret") != null;
                if (field.type == []u8) {
                    const val = @field(self, field.name);
                    if (is_sensitive and val.len > 0) return try allocator.dupe(u8, "***");
                    return try allocator.dupe(u8, if (val.len == 0) "(empty)" else val);
                } else if (field.type == bool) {
                    return try std.fmt.allocPrint(allocator, "{}", .{@field(self, field.name)});
                } else if (field.type == ?bool) {
                    // Tri-state config field (e.g. auto_memory_enabled): show
                    // the user's explicit choice, or "(unset)" when null so a
                    // "default applies" state reads differently from false.
                    const v = @field(self, field.name);
                    return try allocator.dupe(u8, if (v) |b| (if (b) "true" else "false") else "(unset)");
                } else if (field.type == ?usize) {
                    // Optional numeric config field (e.g.
                    // telemetry_cardinality_limit): "(unset)" when null so an
                    // unbounded default reads differently from an explicit 0.
                    const v = @field(self, field.name);
                    return if (v) |n| try std.fmt.allocPrint(allocator, "{d}", .{n}) else try allocator.dupe(u8, "(unset)");
                } else if (field.type == ?[]const []const u8) {
                    // Optional string-list config field (e.g.
                    // telemetry_attribute_allowlist): render as a comma-joined
                    // list, or "(unset)" when null so "no allowlist" reads
                    // differently from "empty allowlist".
                    const v = @field(self, field.name) orelse return try allocator.dupe(u8, "(unset)");
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(allocator);
                    for (v, 0..) |item, i| {
                        if (i != 0) try buf.appendSlice(allocator, ", ");
                        try buf.appendSlice(allocator, item);
                    }
                    return try buf.toOwnedSlice(allocator);
                } else if (field.type == std.array_list.Managed(EnvPair)) {
                    // Settings-sourced env (settings-02): render as a
                    // comma-joined NAME=value list, or "(empty)" when none.
                    const list = @field(self, field.name);
                    if (list.items.len == 0) return try allocator.dupe(u8, "(empty)");
                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(allocator);
                    for (list.items, 0..) |pair, i| {
                        if (i != 0) try buf.appendSlice(allocator, ", ");
                        try buf.appendSlice(allocator, pair.name);
                        try buf.append(allocator, '=');
                        try buf.appendSlice(allocator, pair.value);
                    }
                    return try buf.toOwnedSlice(allocator);
                } else {
                    return try std.fmt.allocPrint(allocator, "{d}", .{@field(self, field.name)});
                }
            }
        }
        return null;
    }
};

pub const LoadedConfig = struct {
    config: Config,
    paths: paths.PathSet,
    workspace_config_path: []u8,
    user_config_found: bool,
    workspace_config_found: bool,
    /// Dangerous keys found across the managed file + drop-ins (settings-03).
    /// null when no managed file was applied. main.zig consults this for the
    /// accept/reject approval gate before starting the REPL.
    managed_dangerous: ?managed_security.DangerousSummary = null,

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        self.paths.deinit(allocator);
        allocator.free(self.workspace_config_path);
        if (self.managed_dangerous) |*d| d.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests -- validation / data-model tests stay here; parsing tests moved to
// config_parse.zig.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "validate rejects invalid token reservations" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.model_context_window = 100;
    cfg.reserved_output_tokens = 101;
    try testing.expectError(error.InvalidReservedOutput, cfg.validate());
}

test "validate rejects enabled policy sync without URL" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.control_plane_policy_sync = true;
    try testing.expectError(error.InvalidControlPlaneUrl, cfg.validate());
}

test "validate rejects enabled managed settings sync without URL" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.control_plane_managed_settings_sync = true;
    try testing.expectError(error.InvalidControlPlaneUrl, cfg.validate());
}

test "validate rejects invalid API profile and role" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try cfg.setOwnedString(allocator, &cfg.api_profile, "admin");
    try testing.expectError(error.InvalidApiProfile, cfg.validate());

    try cfg.setOwnedString(allocator, &cfg.api_profile, "full");
    try cfg.setOwnedString(allocator, &cfg.api_role, "superuser");
    try testing.expectError(error.InvalidApiRole, cfg.validate());
}

test "validate requires API auth material when API auth is enabled" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.api_auth_required = true;
    try testing.expectError(error.InvalidApiAuthConfig, cfg.validate());

    try cfg.setOwnedString(allocator, &cfg.api_bearer_token, "secret");
    try cfg.validate();
}

test "validate requires complete API OIDC settings" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try cfg.setOwnedString(allocator, &cfg.api_oidc_issuer, "https://issuer.example");
    try testing.expectError(error.InvalidApiOidcConfig, cfg.validate());

    try cfg.setOwnedString(allocator, &cfg.api_oidc_audience, "zcode");
    try cfg.setOwnedString(allocator, &cfg.api_oidc_hs256_secret, "shared-secret");
    try cfg.validate();

    try cfg.setOwnedString(allocator, &cfg.api_oidc_hs256_secret, "");
    try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_file, "/etc/zcode/oidc-jwks.json");
    try cfg.validate();

    try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_file, "");
    try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_url, "https://issuer.example/.well-known/jwks.json");
    try cfg.validate();

    try cfg.setOwnedString(allocator, &cfg.api_oidc_jwks_url, "http://issuer.example/.well-known/jwks.json");
    try testing.expectError(error.InvalidApiOidcConfig, cfg.validate());
}

test "validate rejects malformed egress allowlist entries" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try cfg.setOwnedString(allocator, &cfg.egress_allowlist, "https://api.example.com");
    try testing.expectError(error.InvalidEgressAllowlist, cfg.validate());

    try cfg.setOwnedString(allocator, &cfg.egress_allowlist, "api.openai.com,*.anthropic.com");
    try cfg.validate();
}

test "validate rejects malformed egress denylist entries" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    // Scheme in a denylist entry is malformed (same rule as allowlist).
    try cfg.setOwnedString(allocator, &cfg.egress_denylist, "https://evil.com");
    try testing.expectError(error.InvalidEgressDenylist, cfg.validate());

    // A path in a denylist entry is malformed.
    try cfg.setOwnedString(allocator, &cfg.egress_denylist, "evil.com/path");
    try testing.expectError(error.InvalidEgressDenylist, cfg.validate());

    // Well-formed denylist passes.
    try cfg.setOwnedString(allocator, &cfg.egress_denylist, "evil.com,*.bad.example");
    try cfg.validate();
}

test "validate rejects zero instruction import depth" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.instruction_import_max_depth = 0;
    try testing.expectError(error.InvalidInstructionImportDepth, cfg.validate());
}

test "validate accepts valid default config" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try cfg.validate();
}

test "validate rejects empty provider" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.default_provider);
    cfg.default_provider = try allocator.dupe(u8, "");
    try testing.expectError(error.InvalidProvider, cfg.validate());
}

test "validate rejects empty model" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.default_model);
    cfg.default_model = try allocator.dupe(u8, "");
    try testing.expectError(error.InvalidModel, cfg.validate());
}

test "validate rejects zero context window" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.model_context_window = 0;
    try testing.expectError(error.InvalidModelContextWindow, cfg.validate());
}

test "setOwnedString frees previous value" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    try cfg.setOwnedString(allocator, &cfg.default_provider, "anthropic");
    try testing.expectEqualStrings("anthropic", cfg.default_provider);
}

test "validate rejects enabled preprocessor without provider" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.preprocessor_enabled = true;
    try testing.expectError(error.InvalidPreprocessorProvider, cfg.validate());
}

test "validate rejects enabled preprocessor without model" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.preprocessor_enabled = true;
    allocator.free(cfg.preprocessor_provider);
    cfg.preprocessor_provider = try allocator.dupe(u8, "openai");
    try testing.expectError(error.InvalidPreprocessorModel, cfg.validate());
}

test "validate accepts enabled preprocessor with provider and model" {
    const allocator = testing.allocator;
    var cfg = try Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.preprocessor_enabled = true;
    allocator.free(cfg.preprocessor_provider);
    cfg.preprocessor_provider = try allocator.dupe(u8, "openai");
    allocator.free(cfg.preprocessor_model);
    cfg.preprocessor_model = try allocator.dupe(u8, "gpt-4.1-mini");
    try cfg.validate();
}
