const std = @import("std");
const std_io = @import("core/std_io.zig");
const display_safe = @import("core/display_safe.zig");

const config_mod = @import("core/config.zig");
const logger_mod = @import("core/logger.zig");
const benchmark_mod = @import("core/benchmark.zig");
const types = @import("core/types.zig");
const policy_mod = @import("policy/policy.zig");
const providers = @import("providers/mod.zig");
const agent_runtime = @import("agent_runtime.zig");
const repl_commands = @import("repl_commands.zig");
const keychain = @import("core/keychain.zig");

// --- Models commands ---

pub fn cmdModelsList(allocator: std.mem.Allocator, cfg: *const config_mod.Config, writer: anytype) !void {
    const catalog = try repl_commands.resolveModelCatalogForProvider(
        allocator,
        cfg,
        cfg.default_provider,
        cfg.default_model,
    );
    defer {
        for (catalog) |item| allocator.free(item.id);
        allocator.free(catalog);
    }

    for (catalog) |item| {
        // Model IDs come from remote provider APIs (Anthropic,
        // OpenAI, Ollama list-models, OpenRouter). A hostile or
        // compromised provider could inject ANSI escapes via model
        // ID strings; sanitize so the TSV row in `models list`
        // can't be hijacked the same way pass 56 fixed for MCP
        // discovery commands.
        if (parseQualifiedModelRef(item.id)) |qualified| {
            const safe_p = try display_safe.sanitize(allocator, qualified.provider);
            defer allocator.free(safe_p);
            const safe_m = try display_safe.sanitize(allocator, qualified.model);
            defer allocator.free(safe_m);
            try writer.print("{s}\t{s}\tctx={d}\n", .{ safe_p, safe_m, item.context_window });
        } else {
            const safe_id = try display_safe.sanitize(allocator, item.id);
            defer allocator.free(safe_id);
            try writer.print("{s}\t{s}\tctx={d}\n", .{ cfg.default_provider, safe_id, item.context_window });
        }
    }
}

pub fn cmdModelsTest(allocator: std.mem.Allocator, cfg: *const config_mod.Config, model: []const u8, writer: anytype) !void {
    var adapter = try providers.createAdapterWithOverrides(
        allocator,
        cfg.default_provider,
        agent_runtime.providerAdapterOverrides(cfg, cfg.default_provider, false),
    );
    defer adapter.deinit(allocator);

    try adapter.healthcheck(allocator);

    const req = types.ModelRequest{
        .model = model,
        .prompt = "Return the word OK and nothing else.",
        .max_output_tokens = 64,
    };
    const resp = try adapter.send(allocator, req);
    defer allocator.free(resp.raw);
    defer allocator.free(resp.text);

    try writer.print("model test response: {s}\n", .{resp.text});
}

// --- Providers commands ---

pub fn cmdProvidersLogin(provider_name: []const u8, writer: anytype) !void {
    const env_var = providerEnv(provider_name) orelse "<unknown>";
    try writer.print("Set {s} in your environment and rerun `zcode providers status`.\n", .{env_var});
}

pub fn cmdProvidersLogout(provider_name: []const u8, writer: anytype) !void {
    const env_var = providerEnv(provider_name) orelse "<unknown>";
    try writer.print("Unset {s} from your environment to log out.\n", .{env_var});
}

pub fn cmdProvidersStatus(allocator: std.mem.Allocator, cfg: *const config_mod.Config, writer: anytype) !void {
    // Print a row for every provider we actually support. The previous
    // version omitted groq / openrouter / azure, so their rows never
    // showed up in `zcode providers status` even when the operator had
    // the corresponding env var set.
    const providers_list = [_][]const u8{
        "openai",
        "openai-compatible",
        "deepseek",
        "anthropic",
        "gemini",
        "groq",
        "openrouter",
        "azure",
    };
    for (providers_list) |name| {
        const source = providerAuthSource(allocator, cfg, name);
        try writer.print("{s}\tconfigured={}\tsource={s}\n", .{
            name,
            !std.mem.eql(u8, source, "none"),
            source,
        });
    }
    try writer.writeAll("local\tconfigured=true\tsource=default\n");
}

pub fn providerEnv(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "openai")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, name, "openai-compatible")) return "OPENAI_COMPAT_API_KEY";
    if (std.mem.eql(u8, name, "deepseek")) return "DEEPSEEK_API_KEY";
    if (std.mem.eql(u8, name, "anthropic")) return "ANTHROPIC_API_KEY";
    if (std.mem.eql(u8, name, "gemini")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, name, "groq")) return "GROQ_API_KEY";
    if (std.mem.eql(u8, name, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.mem.eql(u8, name, "azure") or std.mem.eql(u8, name, "azure-openai")) return "AZURE_OPENAI_API_KEY";
    return null;
}

// --- Keychain commands ---

pub fn cmdKeychainSet(
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    secret: ?[]const u8,
    writer: anytype,
) !void {
    const p = provider orelse {
        try writer.writeAll("usage: zcode keychain set <provider> <secret>\n");
        return;
    };
    const s = secret orelse {
        try writer.writeAll("usage: zcode keychain set <provider> <secret>\n");
        return;
    };
    keychain.set(allocator, p, s) catch |err| {
        try writer.print("keychain set failed: {s}\n", .{@errorName(err)});
        if (err == error.KeychainLocked) try writer.print("  - {s}\n", .{keychain.keychain_locked_hint});
        return;
    };
    try writer.print("Stored secret for provider '{s}'.\n", .{p});
}

pub fn cmdKeychainGet(
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    writer: anytype,
) !void {
    const p = provider orelse {
        try writer.writeAll("usage: zcode keychain get <provider>\n");
        return;
    };
    const secret = keychain.get(allocator, p) catch |err| {
        try writer.print("keychain get failed: {s}\n", .{@errorName(err)});
        if (err == error.KeychainLocked) try writer.print("  - {s}\n", .{keychain.keychain_locked_hint});
        return;
    };
    defer allocator.free(secret);
    try writer.print("{s}\n", .{secret});
}

pub fn cmdKeychainDelete(
    allocator: std.mem.Allocator,
    provider: ?[]const u8,
    writer: anytype,
) !void {
    const p = provider orelse {
        try writer.writeAll("usage: zcode keychain delete <provider>\n");
        return error.MissingToolArg;
    };
    const found = keychain.delete(allocator, p) catch false;
    if (found) {
        try writer.print("Deleted keychain entry for provider '{s}'.\n", .{p});
        return;
    }
    // Not-found is surfaced as exit 1 for script parity with
    // `mcp remove` / `plugins uninstall` / `commands uninstall`.
    try std_io.stderrWriter().print(
        "error: keychain delete: no keychain entry for provider '{s}'.\n  - Run `zcode keychain list` to see provisioned providers.\n",
        .{p},
    );
    return error.EntryNotInstalled;
}

pub fn cmdKeychainList(
    allocator: std.mem.Allocator,
    writer: anytype,
) !void {
    // We can only enumerate the file-fallback entries reliably (OS
    // keychain enumeration requires platform-specific APIs that we
    // haven't wired up yet). Probe each known provider via get(); if
    // the get succeeds, we know an entry exists without revealing it.
    const names = [_][]const u8{
        "openai",
        "openai-compatible",
        "deepseek",
        "anthropic",
        "gemini",
        "groq",
        "openrouter",
        "azure",
    };
    var any = false;
    for (names) |name| {
        if (keychain.get(allocator, name)) |secret| {
            allocator.free(secret);
            try writer.print("{s}\tstored\n", .{name});
            any = true;
        } else |_| {}
    }
    if (!any) {
        try writer.writeAll("(no keychain entries found)\n");
    }
}

// --- Benchmark command ---

pub fn cmdBenchmarkRun(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *const policy_mod.Policy,
    writer: anytype,
) !void {
    const result = try benchmark_mod.run(allocator, cwd, cfg, policy);
    try writer.print("{f}\n", .{std.json.fmt(result, .{})});
}

// --- Helpers ---

const QualifiedModelRef = struct {
    provider: []const u8,
    model: []const u8,
};

pub fn parseQualifiedModelRef(token: []const u8) ?QualifiedModelRef {
    if (std.mem.indexOfScalar(u8, token, '/')) |slash_idx| {
        const maybe_provider = std.mem.trim(u8, token[0..slash_idx], " \t");
        const maybe_model = std.mem.trim(u8, token[slash_idx + 1 ..], " \t");
        if (maybe_provider.len > 0 and maybe_model.len > 0 and repl_commands.isKnownProviderName(maybe_provider)) {
            return .{
                .provider = maybe_provider,
                .model = maybe_model,
            };
        }
    }
    return null;
}

fn providerAuthSource(allocator: std.mem.Allocator, cfg: *const config_mod.Config, provider_name: []const u8) []const u8 {
    // Keep in precedence order with `makeProviderConfig` in
    // providers/mod.zig: env > keychain > config. Without the keychain
    // probe a provisioned key would show configured=false here even
    // though `zcode run` would happily resolve it on the next call.
    if (providerEnvConfigured(provider_name)) return "env";
    if (keychain.get(allocator, provider_name)) |secret| {
        allocator.free(secret);
        return "keychain";
    } else |_| {}
    if (std.mem.eql(u8, cfg.default_provider, provider_name) and cfg.provider_api_key.len > 0) return "config";
    if (std.mem.eql(u8, cfg.fallback_provider, provider_name) and cfg.fallback_provider_api_key.len > 0) return "config";
    return "none";
}

fn providerEnvConfigured(provider_name: []const u8) bool {
    if (std.mem.eql(u8, provider_name, "openai")) return (@import("core/env.zig").getenv("OPENAI_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "openai-compatible")) return (@import("core/env.zig").getenv("OPENAI_COMPAT_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "deepseek")) return (@import("core/env.zig").getenv("DEEPSEEK_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "anthropic")) return (@import("core/env.zig").getenv("ANTHROPIC_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "gemini")) return (@import("core/env.zig").getenv("GEMINI_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "groq")) return (@import("core/env.zig").getenv("GROQ_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "openrouter")) return (@import("core/env.zig").getenv("OPENROUTER_API_KEY") != null);
    if (std.mem.eql(u8, provider_name, "azure") or std.mem.eql(u8, provider_name, "azure-openai")) {
        return (@import("core/env.zig").getenv("AZURE_OPENAI_API_KEY") != null);
    }
    return false;
}

const testing = std.testing;

test "providerEnv returns correct env var names" {
    try testing.expectEqualStrings("OPENAI_API_KEY", providerEnv("openai").?);
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", providerEnv("anthropic").?);
    try testing.expectEqualStrings("DEEPSEEK_API_KEY", providerEnv("deepseek").?);
    try testing.expectEqualStrings("AZURE_OPENAI_API_KEY", providerEnv("azure").?);
    try testing.expect(providerEnv("local") == null);
    try testing.expect(providerEnv("unknown") == null);
}

test "parseQualifiedModelRef parses provider/model" {
    const ref = parseQualifiedModelRef("openai/gpt-4").?;
    try testing.expectEqualStrings("openai", ref.provider);
    try testing.expectEqualStrings("gpt-4", ref.model);
}

test "parseQualifiedModelRef returns null for plain model" {
    try testing.expect(parseQualifiedModelRef("gpt-4") == null);
    try testing.expect(parseQualifiedModelRef("") == null);
}
