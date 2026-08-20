const std = @import("std");
const config_mod = @import("config.zig");
const env_mod = @import("env.zig");

/// Small-fast (cheap, low-latency) model routing for background work.
///
/// Ported from claude-code-main/src/utils/model.ts:36-38 getSmallFastModel,
/// which returns ANTHROPIC_SMALL_FAST_MODEL (or a default Haiku) and routes
/// cheap background queries -- compaction summaries, titles, classifiers --
/// to it so they do not spend the expensive primary model's tokens/latency.
///
/// zcode already has a partial analog in `preprocessor_model` (intent
/// extraction / context scoring). Rather than overload that field -- which has
/// a semantically distinct job -- this resolver treats the preprocessor model
/// as ONE of the candidate small-fast models, layered under an explicit
/// ZCODE_SMALL_FAST_MODEL env override.
///
/// Resolution precedence (first non-empty wins):
///   1. ZCODE_SMALL_FAST_MODEL env var (analog of ANTHROPIC_SMALL_FAST_MODEL).
///      May be a bare model id ("claude-3-5-haiku") or provider-qualified
///      ("anthropic/claude-3-5-haiku"). Bare ids inherit the active provider.
///   2. preprocessor_model (when the preprocessor is enabled and a model is set).
///   3. the active provider/model (so behavior is UNCHANGED when nothing is
///      configured -- background work keeps using the primary model exactly
///      like today).
///
/// Scope note (matches the phase plan): zcode applies the resolved small-fast
/// model only to compaction summaries for now. The reference also routes
/// titles/classifiers through it, but zcode either lacks those paths or already
/// runs them via the preprocessor. Broader routing is deferred. There is also
/// no Bedrock ANTHROPIC_SMALL_FAST_MODEL_AWS_REGION analog -- zcode does not
/// support Bedrock region overrides, so that is explicitly out of scope.
/// The zcode-namespaced env var name. Exposed so call sites and tests share one
/// spelling instead of re-typing the string literal.
pub const ENV_VAR = "ZCODE_SMALL_FAST_MODEL";

/// A resolved provider/model pair. Both slices are BORROWED from the inputs
/// (env value, preprocessor config, or active model). The caller owns neither
/// and must not free them; their lifetime is the lifetime of whatever backed
/// the chosen branch (config-owned strings or the libc env buffer).
pub const Resolved = struct {
    provider: []const u8,
    model: []const u8,
};

/// Pure resolver. Takes every input explicitly so it is testable without
/// touching the real environment.
///
/// `env_value` is the raw ZCODE_SMALL_FAST_MODEL value (null = unset). When it
/// is a provider-qualified "provider/model" string the embedded provider is
/// used; a bare model id inherits `active_provider`.
pub fn resolve(
    env_value: ?[]const u8,
    preprocessor_enabled: bool,
    preprocessor_provider: []const u8,
    preprocessor_model: []const u8,
    active_provider: []const u8,
    active_model: []const u8,
) Resolved {
    // 1. Explicit env override.
    if (env_value) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (splitQualified(trimmed)) |q| {
                return .{ .provider = q.provider, .model = q.model };
            }
            // Bare model id: keep the active provider, swap only the model.
            return .{ .provider = active_provider, .model = trimmed };
        }
    }

    // 2. Preprocessor model, when the preprocessor is configured.
    if (preprocessor_enabled and preprocessor_model.len > 0) {
        const provider = if (preprocessor_provider.len > 0) preprocessor_provider else active_provider;
        return .{ .provider = provider, .model = preprocessor_model };
    }

    // 3. Fall back to the active model -- unchanged behavior.
    return .{ .provider = active_provider, .model = active_model };
}

/// True when an explicit small-fast model is configured (env override or the
/// preprocessor model), i.e. the resolver would return something OTHER than the
/// active model. Lets call sites cheaply decide whether to build a separate
/// adapter or just reuse the primary one.
pub fn isConfigured(
    env_value: ?[]const u8,
    preprocessor_enabled: bool,
    preprocessor_model: []const u8,
) bool {
    if (env_value) |raw| {
        if (std.mem.trim(u8, raw, " \t\r\n").len > 0) return true;
    }
    return preprocessor_enabled and preprocessor_model.len > 0;
}

/// Convenience wrapper: read the env var via env.getenv and pull the
/// preprocessor fields off the loaded config, given the session's active
/// provider/model. Returns borrowed slices (see `Resolved` lifetime note); the
/// env-backed slice borrows libc's static storage, so the result must be used
/// before any further env mutation.
pub fn fromConfig(
    cfg: *const config_mod.Config,
    active_provider: []const u8,
    active_model: []const u8,
) Resolved {
    return resolve(
        env_mod.getenv(ENV_VAR),
        cfg.preprocessor_enabled,
        cfg.preprocessor_provider,
        cfg.preprocessor_model,
        active_provider,
        active_model,
    );
}

const Qualified = struct {
    provider: []const u8,
    model: []const u8,
};

/// Split a "provider/model" string. Returns null for a bare model id (no
/// slash), an empty provider, or an empty model -- callers then treat the whole
/// string as a bare model id. Only the FIRST slash separates provider from
/// model so model ids that themselves contain slashes survive intact.
fn splitQualified(raw: []const u8) ?Qualified {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return null;
    const provider = raw[0..slash];
    const model = raw[slash + 1 ..];
    if (provider.len == 0 or model.len == 0) return null;
    return .{ .provider = provider, .model = model };
}

const testing = std.testing;

test "resolve: env override (bare model) wins and inherits active provider" {
    const r = resolve(
        "claude-3-5-haiku",
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-3-5-haiku", r.model);
}

test "resolve: env override with provider/model uses the embedded provider" {
    const r = resolve(
        "openrouter/anthropic/claude-3-5-haiku",
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("openrouter", r.provider);
    // Only the first slash splits, so the rest of the id survives.
    try testing.expectEqualStrings("anthropic/claude-3-5-haiku", r.model);
}

test "resolve: env override beats a configured preprocessor model" {
    const r = resolve(
        "claude-3-5-haiku",
        true,
        "openai",
        "gpt-4.1-mini",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-3-5-haiku", r.model);
}

test "resolve: preprocessor model used when env unset" {
    const r = resolve(
        null,
        true,
        "openai",
        "gpt-4.1-mini",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("openai", r.provider);
    try testing.expectEqualStrings("gpt-4.1-mini", r.model);
}

test "resolve: preprocessor model inherits active provider when its provider is blank" {
    const r = resolve(
        null,
        true,
        "",
        "gpt-4.1-mini",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("gpt-4.1-mini", r.model);
}

test "resolve: disabled preprocessor falls through to active model even with a model set" {
    const r = resolve(
        null,
        false,
        "openai",
        "gpt-4.1-mini",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: both unset returns the active provider/model unchanged" {
    const r = resolve(
        null,
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: blank/whitespace env value is ignored" {
    const r = resolve(
        "   ",
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: env value is trimmed before use" {
    const r = resolve(
        "  claude-3-5-haiku  ",
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("claude-3-5-haiku", r.model);
}

test "resolve: malformed provider/model (empty side) treated as bare model id" {
    // Leading slash -> empty provider -> not a valid qualified pair, so the
    // whole string becomes the bare model id under the active provider.
    const r = resolve(
        "/claude-3-5-haiku",
        false,
        "",
        "",
        "anthropic",
        "claude-opus-4-6",
    );
    try testing.expectEqualStrings("anthropic", r.provider);
    try testing.expectEqualStrings("/claude-3-5-haiku", r.model);
}

test "isConfigured reflects whether an explicit small-fast model is set" {
    try testing.expect(isConfigured("claude-3-5-haiku", false, ""));
    try testing.expect(isConfigured(null, true, "gpt-4.1-mini"));
    try testing.expect(!isConfigured(null, false, ""));
    try testing.expect(!isConfigured("   ", false, ""));
    // Preprocessor model set but preprocessor disabled -> not configured.
    try testing.expect(!isConfigured(null, false, "gpt-4.1-mini"));
}

test "fromConfig reads preprocessor fields off the config" {
    const allocator = testing.allocator;
    var cfg = try config_mod.Config.init(allocator);
    defer cfg.deinit(allocator);

    cfg.preprocessor_enabled = true;
    allocator.free(cfg.preprocessor_provider);
    cfg.preprocessor_provider = try allocator.dupe(u8, "openai");
    allocator.free(cfg.preprocessor_model);
    cfg.preprocessor_model = try allocator.dupe(u8, "gpt-4.1-mini");

    // ZCODE_SMALL_FAST_MODEL is assumed unset in the test environment, so the
    // preprocessor model should be chosen. (Tests never set process env here to
    // avoid cross-test contamination; the env branch is covered by resolve().)
    const r = fromConfig(&cfg, "anthropic", "claude-opus-4-6");
    if (env_mod.getenv(ENV_VAR) == null) {
        try testing.expectEqualStrings("openai", r.provider);
        try testing.expectEqualStrings("gpt-4.1-mini", r.model);
    }
}
