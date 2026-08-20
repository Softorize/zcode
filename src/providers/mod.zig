const std = @import("std");
const types = @import("../core/types.zig");
const model_cache = @import("../core/model_cache.zig");
const openai = @import("openai.zig");
const deepseek = @import("deepseek.zig");
const anthropic = @import("anthropic.zig");
const gemini = @import("gemini.zig");
const local = @import("local.zig");
const groq = @import("groq.zig");
const openrouter = @import("openrouter.zig");
const azure = @import("azure.zig");
const mock = @import("mock.zig");

pub const AdapterOverrides = struct {
    api_key: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    retry_count: ?u8 = null,
};

pub fn createAdapter(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    base_url_override: ?[]const u8,
) !types.ProviderAdapter {
    return createAdapterWithOverrides(allocator, provider_name, .{
        .base_url = base_url_override,
    });
}

pub fn createAdapterWithOverrides(
    allocator: std.mem.Allocator,
    provider_name: []const u8,
    overrides: AdapterOverrides,
) !types.ProviderAdapter {
    var cfg = try makeProviderConfig(allocator, provider_name, overrides);
    defer cfg.deinit(allocator);

    if (std.mem.eql(u8, provider_name, "openai")) {
        return openai.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return anthropic.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "gemini")) {
        return gemini.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "local") or std.mem.eql(u8, provider_name, "ollama")) {
        return local.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "openai-compatible")) {
        return openai.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "deepseek")) {
        return deepseek.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "groq")) {
        return groq.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "openrouter")) {
        return openrouter.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "azure") or std.mem.eql(u8, provider_name, "azure-openai")) {
        return azure.create(allocator, cfg.toTypes());
    }
    if (std.mem.eql(u8, provider_name, "mock")) {
        return mock.create(allocator, cfg.toTypes());
    }

    return error.UnsupportedProvider;
}

/// Like adapter.listModels but with a 1-hour disk cache in ~/.zcode/models_cache.json.
/// Falls back to a live API call on cache miss/expiry, then saves the result.
pub fn listModelsCached(allocator: std.mem.Allocator, adapter: *types.ProviderAdapter, provider_name: []const u8) ![]types.ModelInfo {
    if (model_cache.loadCached(allocator, provider_name)) |cached| return cached;
    const models = try adapter.listModels(allocator);
    model_cache.saveCache(allocator, provider_name, models);
    return models;
}

pub fn freeModelInfos(allocator: std.mem.Allocator, models: []types.ModelInfo) void {
    for (models) |model| {
        allocator.free(model.id);
        allocator.free(model.provider);
    }
    allocator.free(models);
}

const ProviderConfigOwned = struct {
    name: []u8,
    api_key: ?[]u8,
    base_url: ?[]u8,
    timeout_ms: u32,
    retry_count: u8,

    pub fn deinit(self: *ProviderConfigOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.api_key) |v| allocator.free(v);
        if (self.base_url) |v| allocator.free(v);
    }

    pub fn toTypes(self: *const ProviderConfigOwned) types.ProviderConfig {
        return .{
            .name = self.name,
            .api_key = if (self.api_key) |v| v else null,
            .base_url = if (self.base_url) |v| v else null,
            .timeout_ms = self.timeout_ms,
            .retry_count = self.retry_count,
        };
    }
};

fn makeProviderConfig(allocator: std.mem.Allocator, provider_name: []const u8, overrides: AdapterOverrides) !ProviderConfigOwned {
    const name = try allocator.dupe(u8, provider_name);

    var api_key: ?[]u8 = null;
    if (std.mem.eql(u8, provider_name, "openai")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "OPENAI_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "openai-compatible")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "OPENAI_COMPAT_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "deepseek")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "DEEPSEEK_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "anthropic")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "ANTHROPIC_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "gemini")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "GEMINI_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "groq")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "GROQ_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "openrouter")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "OPENROUTER_API_KEY") catch null;
    } else if (std.mem.eql(u8, provider_name, "azure") or std.mem.eql(u8, provider_name, "azure-openai")) {
        api_key = @import("../core/env.zig").getOwned(allocator, "AZURE_OPENAI_API_KEY") catch null;
    }

    // OS keychain fallback: if no env var is set and no explicit
    // override is incoming, look the key up in the platform keychain.
    // Enterprise deployments can provision secrets there once and
    // avoid keeping them in shell env or TOML config. Env still wins
    // (set by dev tooling, CI, etc.); keychain only backfills.
    if (api_key == null and overrides.api_key == null) {
        if (@import("../core/keychain.zig").get(allocator, provider_name)) |from_kc| {
            api_key = from_kc;
        } else |_| {}
    }

    var env_base_url = if (std.mem.eql(u8, provider_name, "openai"))
        @import("../core/env.zig").getOwned(allocator, "OPENAI_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "openai-compatible"))
        @import("../core/env.zig").getOwned(allocator, "OPENAI_COMPAT_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "deepseek"))
        @import("../core/env.zig").getOwned(allocator, "DEEPSEEK_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "anthropic"))
        @import("../core/env.zig").getOwned(allocator, "ANTHROPIC_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "gemini"))
        @import("../core/env.zig").getOwned(allocator, "GEMINI_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "local") or std.mem.eql(u8, provider_name, "ollama"))
        @import("../core/env.zig").getOwned(allocator, "OLLAMA_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "groq"))
        @import("../core/env.zig").getOwned(allocator, "GROQ_BASE_URL") catch null
    else if (std.mem.eql(u8, provider_name, "openrouter"))
        @import("../core/env.zig").getOwned(allocator, "OPENROUTER_BASE_URL") catch null
    else
        null;

    const default_base_url = if (std.mem.eql(u8, provider_name, "deepseek"))
        "https://api.deepseek.com"
    else
        null;

    if (overrides.api_key) |v| {
        if (api_key) |existing| allocator.free(existing);
        api_key = try allocator.dupe(u8, v);
    }

    var base_url: ?[]u8 = null;
    if (overrides.base_url) |v| {
        base_url = try allocator.dupe(u8, v);
    } else if (env_base_url) |v| {
        base_url = v;
        env_base_url = null;
    } else if (default_base_url) |v| {
        base_url = try allocator.dupe(u8, v);
    }
    defer if (env_base_url) |v| allocator.free(v);

    return .{
        .name = name,
        .api_key = api_key,
        .base_url = base_url,
        .timeout_ms = overrides.timeout_ms orelse 60_000,
        .retry_count = overrides.retry_count orelse 2,
    };
}

const testing = std.testing;
test "createAdapter rejects unknown" {
    try testing.expectError(error.UnsupportedProvider, createAdapter(testing.allocator, "nope", null));
}
