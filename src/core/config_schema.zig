//! settings-12: machine-readable settings schema export.
//!
//! `zcode config schema` emits a JSON Schema (draft-07 flavored) enumerating
//! every config key that `config_parse.applyKeyValue` accepts, with the JSON
//! type implied by that key's parser (string / boolean / integer) plus enum
//! hints for the handful of closed-set keys. Editors and config linters can
//! load it for completion and validation.
//!
//! Single source of truth: `keys` below is the canonical list. A test in this
//! module feeds every entry through `applyKeyValue` and asserts none returns
//! `error.UnknownConfigKey`, so the schema can never drift to list a key the
//! parser does not actually accept. Keeping the list complete (covering every
//! parser branch) is a manual discipline noted next to `applyKeyValue`; the
//! test guarantees the subset direction (schema keys are real keys).
//!
//! No external $id / schemastore URL: this is a local, self-describing export
//! for tooling, not a published, network-fetched schema.

const std = @import("std");
const config_parse = @import("config_parse.zig");
const config_mod = @import("config.zig");
const std_io = @import("std_io.zig");

/// JSON type a config value parses to. Mirrors the three parser families in
/// `applyKeyValue`: `setOwnedString*` (string), `parseBool` (boolean), and
/// `parseConfigInt` (integer).
pub const Kind = enum {
    string,
    boolean,
    integer,
    number,

    fn jsonType(self: Kind) []const u8 {
        return switch (self) {
            .string => "string",
            .boolean => "boolean",
            .integer => "integer",
            .number => "number",
        };
    }
};

pub const KeySpec = struct {
    name: []const u8,
    kind: Kind,
    /// Closed value set for enum-style string keys, or null when free-form.
    /// Only the keys whose accepted set is a small fixed list (validated
    /// elsewhere in config.zig) carry hints here.
    enum_values: ?[]const []const u8 = null,
};

const approval_modes = [_][]const u8{ "tiered-auto", "manual", "strict" };
// ui-dialogs-03: persisted default permission mode set by the AutoMode opt-in
// dialog's accept-default branch. Mirrors the reference's permissions.defaultMode.
const default_modes = [_][]const u8{"auto"};
const sandbox_profiles = [_][]const u8{ "workspace-write", "read-only", "no-network", "danger-full-access", "none" };
const api_profiles = [_][]const u8{ "read-only", "readonly", "editor", "full" };
const api_roles = [_][]const u8{ "none", "viewer", "auditor", "editor", "owner" };
const ui_densities = [_][]const u8{ "full", "clean" };
const notif_channels = [_][]const u8{ "auto", "iterm2", "iterm2_with_bell", "kitty", "ghostty", "terminal_bell", "notifications_disabled" };
const effort_levels = [_][]const u8{ "auto", "low", "medium", "high", "max" };

/// Canonical list of every key `config_parse.applyKeyValue` accepts. Keep in
/// sync with the `applyKeyValue` branch list. The in-module test enforces the
/// "every entry is a real key" direction.
pub const keys = [_]KeySpec{
    // Provider / model
    .{ .name = "default_provider", .kind = .string },
    .{ .name = "default_model", .kind = .string },
    .{ .name = "available_models", .kind = .string },
    .{ .name = "fallback_provider", .kind = .string },
    .{ .name = "fallback_model", .kind = .string },
    .{ .name = "small_fast_model", .kind = .string },
    .{ .name = "provider_api_key", .kind = .string },
    .{ .name = "provider_base_url", .kind = .string },
    .{ .name = "local_base_url", .kind = .string },
    .{ .name = "fallback_provider_api_key", .kind = .string },
    .{ .name = "fallback_provider_base_url", .kind = .string },
    .{ .name = "provider_timeout_ms", .kind = .integer },
    .{ .name = "provider_retry_count", .kind = .integer },
    .{ .name = "profile", .kind = .string },
    // Approval / sandbox
    .{ .name = "approval_mode", .kind = .string, .enum_values = &approval_modes },
    .{ .name = "default_mode", .kind = .string, .enum_values = &default_modes },
    .{ .name = "sandbox", .kind = .string, .enum_values = &sandbox_profiles },
    // Runtime behavior
    .{ .name = "interactive_streaming", .kind = .boolean },
    .{ .name = "intent_reprompt_enabled", .kind = .boolean },
    // UI
    .{ .name = "ui_fullscreen", .kind = .boolean },
    .{ .name = "ui_alt_screen", .kind = .boolean },
    .{ .name = "ui_spinner", .kind = .boolean },
    .{ .name = "ui_thinking_summary", .kind = .boolean },
    .{ .name = "ui_brief_mode", .kind = .boolean },
    .{ .name = "ui_vim_mode", .kind = .boolean },
    .{ .name = "ui_auto_mode_opt_in_seen", .kind = .boolean },
    .{ .name = "skip_dangerous_mode_permission_prompt", .kind = .boolean },
    .{ .name = "ui_idle_return_never_ask", .kind = .boolean },
    .{ .name = "ui_density", .kind = .string, .enum_values = &ui_densities },
    .{ .name = "ui_leader_key", .kind = .string },
    .{ .name = "ui_show_top_bar", .kind = .boolean },
    .{ .name = "ui_show_shortcuts_panel", .kind = .boolean },
    .{ .name = "ui_prompt_label", .kind = .string },
    .{ .name = "ui_transcript_max_lines", .kind = .integer },
    .{ .name = "ui_show_scroll_hint", .kind = .boolean },
    .{ .name = "ui_bottom_margin_rows", .kind = .integer },
    .{ .name = "ui_line_spacing", .kind = .integer },
    .{ .name = "ui_color_enabled", .kind = .boolean },
    .{ .name = "ui_theme", .kind = .string },
    .{ .name = "ui_highlight_links", .kind = .boolean },
    .{ .name = "ui_highlight_paths", .kind = .boolean },
    .{ .name = "ui_color_lists", .kind = .boolean },
    .{ .name = "ui_highlight_code_blocks", .kind = .boolean },
    .{ .name = "ui_status_show_workspace", .kind = .boolean },
    .{ .name = "ui_status_show_model", .kind = .boolean },
    .{ .name = "ui_status_show_safety", .kind = .boolean },
    .{ .name = "ui_status_show_tokens", .kind = .boolean },
    .{ .name = "ui_status_show_hint", .kind = .boolean },
    // Control plane
    .{ .name = "control_plane_url", .kind = .string },
    .{ .name = "control_plane_token", .kind = .string },
    .{ .name = "control_plane_policy_sync", .kind = .boolean },
    .{ .name = "control_plane_policy_verify_hash", .kind = .boolean },
    .{ .name = "control_plane_managed_settings_sync", .kind = .boolean },
    .{ .name = "control_plane_managed_settings_verify_hash", .kind = .boolean },
    .{ .name = "cloud_telemetry_opt_in", .kind = .boolean },
    // Egress
    .{ .name = "egress_allowlist", .kind = .string },
    .{ .name = "egress_denylist", .kind = .string },
    .{ .name = "egress_allow_private_network_plaintext", .kind = .boolean },
    .{ .name = "egress_allow_unix_sockets", .kind = .boolean },
    .{ .name = "egress_http_proxy_port", .kind = .integer },
    .{ .name = "egress_socks_proxy_port", .kind = .integer },
    // Model / context windows
    .{ .name = "model_context_window", .kind = .integer },
    .{ .name = "reserved_output_tokens", .kind = .integer },
    .{ .name = "reserved_reasoning_tokens", .kind = .integer },
    // Instructions
    .{ .name = "instruction_file_cap_bytes", .kind = .integer },
    .{ .name = "instruction_total_cap_bytes", .kind = .integer },
    .{ .name = "instruction_imports_enabled", .kind = .boolean },
    .{ .name = "instruction_import_max_depth", .kind = .integer },
    .{ .name = "prompt_cache_hints_enabled", .kind = .boolean },
    // Misc behavior
    .{ .name = "feature_kill_switches", .kind = .string },
    .{ .name = "preferred_notif_channel", .kind = .string, .enum_values = &notif_channels },
    .{ .name = "output_style", .kind = .string },
    .{ .name = "append_system_prompt", .kind = .string },
    .{ .name = "max_history_turns", .kind = .integer },
    .{ .name = "max_tool_rounds", .kind = .integer },
    .{ .name = "max_budget_usd", .kind = .number },
    .{ .name = "max_structured_output_retries", .kind = .integer },
    .{ .name = "tool_output_artifact_threshold_bytes", .kind = .integer },
    .{ .name = "mcp_tool_bridge_enabled", .kind = .boolean },
    .{ .name = "browser_bridge_enabled", .kind = .boolean },
    .{ .name = "browser_bridge_port", .kind = .integer },
    // API server auth
    .{ .name = "api_profile", .kind = .string, .enum_values = &api_profiles },
    .{ .name = "api_role", .kind = .string, .enum_values = &api_roles },
    .{ .name = "api_auth_required", .kind = .boolean },
    .{ .name = "api_bearer_token", .kind = .string },
    .{ .name = "api_oidc_issuer", .kind = .string },
    .{ .name = "api_oidc_audience", .kind = .string },
    .{ .name = "api_oidc_hs256_secret", .kind = .string },
    .{ .name = "api_oidc_jwks_json", .kind = .string },
    .{ .name = "api_oidc_jwks_file", .kind = .string },
    .{ .name = "api_oidc_jwks_url", .kind = .string },
    .{ .name = "api_oidc_jwks_cache_ttl_seconds", .kind = .integer },
    // Update
    .{ .name = "update_require_signature", .kind = .boolean },
    .{ .name = "update_pinned_version", .kind = .string },
    // Session / privacy
    .{ .name = "session_encryption_enabled", .kind = .boolean },
    .{ .name = "privacy_redact_prompt_bodies", .kind = .boolean },
    .{ .name = "session_retention_days", .kind = .integer },
    .{ .name = "audit_retention_days", .kind = .integer },
    // Preprocessor
    .{ .name = "preprocessor_enabled", .kind = .boolean },
    .{ .name = "preprocessor_provider", .kind = .string },
    .{ .name = "preprocessor_model", .kind = .string },
    .{ .name = "preprocessor_base_url", .kind = .string },
    .{ .name = "preprocessor_max_output_tokens", .kind = .integer },
    .{ .name = "preprocessor_api_key", .kind = .string },
    // Language (two accepted spellings map to one field)
    .{ .name = "preferred_language", .kind = .string },
    .{ .name = "language", .kind = .string },
    // Memory / dream
    .{ .name = "auto_memory_enabled", .kind = .boolean },
    .{ .name = "auto_memory_directory", .kind = .string },
    .{ .name = "auto_dream_enabled", .kind = .boolean },
    .{ .name = "auto_dream_min_hours", .kind = .integer },
    .{ .name = "auto_dream_min_sessions", .kind = .integer },
    // Spinner tips
    .{ .name = "spinner_tips_enabled", .kind = .boolean },
    .{ .name = "spinner_tips_custom", .kind = .string },
    .{ .name = "spinner_tips_exclude_default", .kind = .boolean },
    // Reasoning effort (commands-sweep-08): persisted /effort level.
    .{ .name = "reasoning_effort", .kind = .string, .enum_values = &effort_levels },
};

/// Emit the schema as JSON to `writer`. Stable, deterministic field order so a
/// diff of two exports is meaningful. The output is a single JSON object; the
/// trailing newline is the caller's standard CLI convention.
pub fn writeSchema(writer: anytype) !void {
    try writer.writeAll("{\n");
    try writer.writeAll("  \"$schema\": \"http://json-schema.org/draft-07/schema#\",\n");
    try writer.writeAll("  \"title\": \"zcode config.toml\",\n");
    try writer.writeAll("  \"description\": \"Keys accepted by zcode config.toml and `config set`. Types follow the parser family for each key.\",\n");
    try writer.writeAll("  \"type\": \"object\",\n");
    try writer.writeAll("  \"additionalProperties\": false,\n");
    try writer.writeAll("  \"properties\": {\n");

    for (keys, 0..) |spec, i| {
        try writer.writeAll("    ");
        try writeJsonString(writer, spec.name);
        try writer.writeAll(": { \"type\": ");
        try writeJsonString(writer, spec.kind.jsonType());
        if (spec.enum_values) |vals| {
            try writer.writeAll(", \"enum\": [");
            for (vals, 0..) |v, vi| {
                if (vi > 0) try writer.writeAll(", ");
                try writeJsonString(writer, v);
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(" }");
        if (i + 1 < keys.len) try writer.writeAll(",");
        try writer.writeAll("\n");
    }

    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");
}

/// Minimal JSON string writer: quote and escape the characters JSON requires.
/// Config key names and enum values are ASCII identifiers, but escaping keeps
/// the emitter correct if a value ever contains a quote or backslash.
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
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

test "config schema: every listed key is accepted by applyKeyValue" {
    // The subset guarantee: each key the schema advertises must be a key the
    // parser actually accepts. A key dropped from applyKeyValue without being
    // dropped here would surface as error.UnknownConfigKey below.
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    for (keys) |spec| {
        // A boolean/integer key needs a parseable value; a free-form string
        // takes anything. "1" satisfies both bool ("1" -> true) and integer
        // parsers. A closed-set string key (enum_values) may validate its value
        // (e.g. reasoning_effort rejects "1"), so feed the first accepted value.
        const value: []const u8 = if (spec.enum_values) |vals| vals[0] else "1";
        config_parse.applyKeyValue(allocator, &cfg, spec.name, value) catch |err| {
            std.debug.print("key '{s}' rejected by applyKeyValue: {s}\n", .{ spec.name, @errorName(err) });
            return err;
        };
    }
}

test "config schema: emitted document is valid JSON" {
    const allocator = testing.allocator;
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeSchema(buf.writer());
    const json = buf.items();

    // Round-trip through the JSON parser: a syntax error would throw here.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);

    const props = parsed.value.object.get("properties") orelse return error.MissingProperties;
    try testing.expect(props == .object);
    // Every canonical key must appear as a property.
    for (keys) |spec| {
        const entry = props.object.get(spec.name) orelse {
            std.debug.print("schema is missing property '{s}'\n", .{spec.name});
            return error.MissingKey;
        };
        try testing.expect(entry == .object);
        const ty = entry.object.get("type") orelse return error.MissingType;
        try testing.expect(ty == .string);
        try testing.expectEqualStrings(spec.kind.jsonType(), ty.string);
    }
}

test "config schema: enum keys carry their value set" {
    const allocator = testing.allocator;
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try writeSchema(buf.writer());

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buf.items(), .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;

    const approval = props.get("approval_mode").?.object;
    const en = approval.get("enum") orelse return error.MissingEnum;
    try testing.expect(en == .array);
    try testing.expectEqual(@as(usize, 3), en.array.items.len);
    try testing.expectEqualStrings("tiered-auto", en.array.items[0].string);

    // A free-form string key must NOT carry an enum.
    const base_url = props.get("provider_base_url").?.object;
    try testing.expect(base_url.get("enum") == null);
}
