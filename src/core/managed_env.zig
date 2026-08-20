const std = @import("std");

/// Environment variables that control inference routing: which provider to
/// use, which endpoint to hit, and which model IDs to send.
///
/// Ported from claude-code-main/src/utils/managedEnvConstants.ts:14-70
/// (PROVIDER_MANAGED_ENV_VARS). When CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST is
/// truthy in the spawn env, these are stripped from settings-sourced env so
/// the host's routing config is not overridden by a user's config.toml `[env]`
/// block (e.g. a Bedrock setup that would break a host that only supports
/// first-party auth).
///
/// Matching is case-insensitive; VERTEX_REGION_CLAUDE_* is prefix-matched so
/// new per-model region overrides do not require a list edit on each launch.
const PROVIDER_MANAGED_ENV_VARS = [_][]const u8{
    // The flag itself -- settings cannot unset it once the host set it.
    "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST",
    // Provider selection.
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    // Endpoint config (base URLs, project/resource identifiers).
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_BEDROCK_BASE_URL",
    "ANTHROPIC_VERTEX_BASE_URL",
    "ANTHROPIC_FOUNDRY_BASE_URL",
    "ANTHROPIC_FOUNDRY_RESOURCE",
    "ANTHROPIC_VERTEX_PROJECT_ID",
    // Region routing (per-model VERTEX_REGION_CLAUDE_* handled by prefix).
    "CLOUD_ML_REGION",
    // Auth.
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "AWS_BEARER_TOKEN_BEDROCK",
    "ANTHROPIC_FOUNDRY_API_KEY",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
    "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
    // Model defaults -- often set to provider-specific ID formats.
    "ANTHROPIC_MODEL",
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
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION",
    "CLAUDE_CODE_SUBAGENT_MODEL",
};

const PROVIDER_MANAGED_ENV_PREFIXES = [_][]const u8{
    // Per-model Vertex region overrides -- scales with model releases, so
    // prefix-matched to avoid drift on each launch.
    "VERTEX_REGION_CLAUDE_",
};

/// The host-routing flag itself. Settings-sourced env must never override it
/// once the host set it, so callers keep it un-strippable separately from the
/// general provider-managed set.
pub const PROVIDER_MANAGED_FLAG = "CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST";

/// True when `key` names a provider-managed routing variable (case-insensitive
/// exact match against the set, or a prefix match against the prefix list).
/// Mirrors managedEnvConstants.ts isProviderManagedEnvVar.
pub fn isProviderManagedEnvVar(key: []const u8) bool {
    for (PROVIDER_MANAGED_ENV_VARS) |candidate| {
        if (std.ascii.eqlIgnoreCase(key, candidate)) return true;
    }
    for (PROVIDER_MANAGED_ENV_PREFIXES) |prefix| {
        if (key.len >= prefix.len and std.ascii.startsWithIgnoreCase(key, prefix)) return true;
    }
    return false;
}

const testing = std.testing;

test "isProviderManagedEnvVar matches the set case-insensitively" {
    try testing.expect(isProviderManagedEnvVar("anthropic_base_url"));
    try testing.expect(isProviderManagedEnvVar("ANTHROPIC_BASE_URL"));
    try testing.expect(isProviderManagedEnvVar("AnThRoPiC_ApI_kEy"));
    try testing.expect(isProviderManagedEnvVar("CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST"));
}

test "isProviderManagedEnvVar matches the VERTEX_REGION_CLAUDE_ prefix" {
    try testing.expect(isProviderManagedEnvVar("VERTEX_REGION_CLAUDE_4_5_SONNET"));
    try testing.expect(isProviderManagedEnvVar("vertex_region_claude_anything"));
    // The bare prefix with nothing after still matches (>= len + startsWith).
    try testing.expect(isProviderManagedEnvVar("VERTEX_REGION_CLAUDE_"));
}

test "isProviderManagedEnvVar returns false for ordinary vars" {
    try testing.expect(!isProviderManagedEnvVar("MY_VAR"));
    try testing.expect(!isProviderManagedEnvVar("PATH"));
    try testing.expect(!isProviderManagedEnvVar("HTTP_PROXY"));
    try testing.expect(!isProviderManagedEnvVar(""));
    // A near-prefix that is shorter than the prefix must not match.
    try testing.expect(!isProviderManagedEnvVar("VERTEX_REGION"));
}
