const std = @import("std");

/// One documented environment variable zcode reads.
pub const EnvEntry = struct {
    name: []const u8,
    category: Category,
    description: []const u8,
    sensitive: bool,

    pub const Category = enum {
        provider_key,
        provider_endpoint,
        zcode_config,
        xdg,
        system,

        pub fn label(self: Category) []const u8 {
            return switch (self) {
                .provider_key => "provider API keys",
                .provider_endpoint => "provider endpoints",
                .zcode_config => "zcode config",
                .xdg => "XDG base dirs",
                .system => "system",
            };
        }
    };
};

/// Authoritative list of env vars zcode reads. Keeping it here rather
/// than scanning source at runtime means users always get the same
/// list regardless of code path; adding a new env lookup should be
/// accompanied by a new entry here so `/env` and `--list-env` stay
/// accurate.
pub const entries = [_]EnvEntry{
    // ── Provider API keys (sensitive) ─────────────────────────────
    .{ .name = "OPENAI_API_KEY", .category = .provider_key, .description = "OpenAI SDK key", .sensitive = true },
    .{ .name = "ANTHROPIC_API_KEY", .category = .provider_key, .description = "Anthropic SDK key", .sensitive = true },
    .{ .name = "GEMINI_API_KEY", .category = .provider_key, .description = "Google Gemini key", .sensitive = true },
    .{ .name = "DEEPSEEK_API_KEY", .category = .provider_key, .description = "DeepSeek key", .sensitive = true },
    .{ .name = "GROQ_API_KEY", .category = .provider_key, .description = "Groq key", .sensitive = true },
    .{ .name = "OPENROUTER_API_KEY", .category = .provider_key, .description = "OpenRouter key", .sensitive = true },
    .{ .name = "AZURE_OPENAI_API_KEY", .category = .provider_key, .description = "Azure OpenAI key", .sensitive = true },
    .{ .name = "OPENAI_COMPAT_API_KEY", .category = .provider_key, .description = "Generic OpenAI-compatible endpoint key", .sensitive = true },

    // ── Provider base URLs (not sensitive) ────────────────────────
    .{ .name = "OPENAI_BASE_URL", .category = .provider_endpoint, .description = "Override OpenAI base URL", .sensitive = false },
    .{ .name = "ANTHROPIC_BASE_URL", .category = .provider_endpoint, .description = "Override Anthropic base URL", .sensitive = false },
    .{ .name = "GEMINI_BASE_URL", .category = .provider_endpoint, .description = "Override Gemini base URL", .sensitive = false },
    .{ .name = "DEEPSEEK_BASE_URL", .category = .provider_endpoint, .description = "Override DeepSeek base URL", .sensitive = false },
    .{ .name = "GROQ_BASE_URL", .category = .provider_endpoint, .description = "Override Groq base URL", .sensitive = false },
    .{ .name = "OPENROUTER_BASE_URL", .category = .provider_endpoint, .description = "Override OpenRouter base URL", .sensitive = false },
    .{ .name = "OPENROUTER_SITE_URL", .category = .provider_endpoint, .description = "Site URL sent to OpenRouter for rate-limit attribution", .sensitive = false },
    .{ .name = "OPENAI_COMPAT_BASE_URL", .category = .provider_endpoint, .description = "Base URL for a generic OpenAI-compatible endpoint", .sensitive = false },
    .{ .name = "OLLAMA_BASE_URL", .category = .provider_endpoint, .description = "Base URL for local Ollama server", .sensitive = false },
    .{ .name = "AZURE_OPENAI_RESOURCE", .category = .provider_endpoint, .description = "Azure OpenAI resource name", .sensitive = false },
    .{ .name = "AZURE_OPENAI_API_VERSION", .category = .provider_endpoint, .description = "Azure OpenAI API version", .sensitive = false },

    // ── zcode runtime config ──────────────────────────────────────
    .{ .name = "ZCODE_VERBOSE", .category = .zcode_config, .description = "Truthy value enables verbose diagnostic logging (same as --verbose)", .sensitive = false },
    .{ .name = "ZCODE_SESSION_KEY", .category = .zcode_config, .description = "32-byte AES-256-GCM key for encrypted session storage (hex:, base64:, or raw)", .sensitive = true },
    .{ .name = "ZCODE_DAEMON_TOKEN", .category = .zcode_config, .description = "Shared secret for the remote-daemon auth check", .sensitive = true },
    .{ .name = "ZCODE_SESSIONS_DIR", .category = .zcode_config, .description = "Override the base sessions directory; the live-process registry lives under <dir>/registry/ (used by zcode ps; tests point this at a tmp dir)", .sensitive = false },
    .{ .name = "ZCODE_SESSION_KIND", .category = .zcode_config, .description = "Session kind a spawned child self-registers as (interactive|bg|daemon|daemon-worker); a --bg/daemon spawner sets it in the child env, defaults to interactive when unset", .sensitive = false },
    .{ .name = "ZCODE_SESSION_LOG", .category = .zcode_config, .description = "Path of the per-session log file a --bg child redirects stdout/stderr into; the spawner sets it and the child records it in the live-process registry (used by zcode logs)", .sensitive = false },
    .{ .name = "ZCODE_SESSION_NAME", .category = .zcode_config, .description = "Display name a spawned child self-registers under (the -n/--name value); a --bg spawner sets it in the child env so the detached session names itself in zcode ps and session list", .sensitive = false },
    .{ .name = "ZCODE_FILE_READ_MAX_TOKENS", .category = .zcode_config, .description = "Cap for Read-tool output in tokens", .sensitive = false },
    .{ .name = "ZCODE_FILE_READ_MAX_BYTES", .category = .zcode_config, .description = "Cap for Read-tool output in bytes", .sensitive = false },
    .{ .name = "ZCODE_FILE_WRITE_MAX_BYTES", .category = .zcode_config, .description = "Cap for Write-tool input in bytes", .sensitive = false },
    .{ .name = "ZCODE_SKIP_READ_BEFORE_EDIT", .category = .zcode_config, .description = "Truthy: skip the mandatory Read before Edit", .sensitive = false },
    .{ .name = "ZCODE_ALLOW_BASH_BANNED", .category = .zcode_config, .description = "Truthy: allow bash commands on the default-banned list", .sensitive = false },
    .{ .name = "ZCODE_BASH_DEFAULT_TIMEOUT_MS", .category = .zcode_config, .description = "Default bash timeout in ms", .sensitive = false },
    .{ .name = "ZCODE_BASH_MAX_TIMEOUT_MS", .category = .zcode_config, .description = "Maximum bash timeout in ms", .sensitive = false },
    .{ .name = "ZCODE_MAX_LINE_BYTES", .category = .zcode_config, .description = "Max bytes per line in the REPL input", .sensitive = false },
    .{ .name = "ZCODE_DEBUG_SCROLL", .category = .zcode_config, .description = "Truthy: enable scroll-handler debug logging", .sensitive = false },
    .{ .name = "ZCODE_MOCK_RESPONSE", .category = .zcode_config, .description = "For tests: return this string as the model response", .sensitive = false },
    .{ .name = "ZCODE_MOCK_RESPONSES", .category = .zcode_config, .description = "For tests: JSON array of mock responses", .sensitive = false },
    .{ .name = "ZCODE_OVERRIDE_DATE", .category = .zcode_config, .description = "For tests: override `today's date` in prompts", .sensitive = false },
    .{ .name = "ZCODE_UPDATE_MANIFEST_URL", .category = .zcode_config, .description = "Override the self-update manifest URL", .sensitive = false },
    .{ .name = "ZCODE_UPDATE_PINNED_VERSION", .category = .zcode_config, .description = "Enterprise hold: pin the updater to a specific X.Y.Z release; newer releases are refused", .sensitive = false },
    .{ .name = "ZCODE_ALLOW_UNSIGNED_UPDATE", .category = .zcode_config, .description = "Truthy: let the auto-updater proceed when the checksum manifest entry is missing", .sensitive = false },
    .{ .name = "ZCODE_UPDATE_REQUIRE_SIGNATURE", .category = .zcode_config, .description = "Truthy: updater fails closed when cosign signature verification cannot complete", .sensitive = false },
    .{ .name = "ZCODE_REDUCE_MOTION", .category = .zcode_config, .description = "Any non-empty value disables the thinking spinner animation", .sensitive = false },
    .{ .name = "ZCODE_API_PROFILE", .category = .zcode_config, .description = "Restrict zcode api serve methods: read-only, editor, or full", .sensitive = false },
    .{ .name = "ZCODE_API_ROLE", .category = .zcode_config, .description = "Minimum role for zcode api serve when no OIDC role claim is supplied: none, viewer, auditor, editor, owner", .sensitive = false },
    .{ .name = "ZCODE_API_AUTH_REQUIRED", .category = .zcode_config, .description = "Truthy: require each JSONL API request to include auth.bearer, auth.id_token, or Authorization: Bearer", .sensitive = false },
    .{ .name = "ZCODE_API_BEARER_TOKEN", .category = .zcode_config, .description = "Shared bearer token accepted by zcode api serve when API auth is required", .sensitive = true },
    .{ .name = "ZCODE_API_OIDC_ISSUER", .category = .zcode_config, .description = "Expected issuer for OIDC/JWT tokens accepted by zcode api serve", .sensitive = false },
    .{ .name = "ZCODE_API_OIDC_AUDIENCE", .category = .zcode_config, .description = "Expected audience for OIDC/JWT tokens accepted by zcode api serve", .sensitive = false },
    .{ .name = "ZCODE_API_OIDC_HS256_SECRET", .category = .zcode_config, .description = "Shared HS256 secret for API OIDC/JWT validation", .sensitive = true },
    .{ .name = "ZCODE_API_OIDC_JWKS_JSON", .category = .zcode_config, .description = "Pinned JWKS JSON for RS256 API OIDC/JWT validation", .sensitive = true },
    .{ .name = "ZCODE_API_OIDC_JWKS_FILE", .category = .zcode_config, .description = "Path to a pinned JWKS JSON file for RS256 API OIDC/JWT validation", .sensitive = false },
    .{ .name = "ZCODE_API_OIDC_JWKS_URL", .category = .zcode_config, .description = "HTTPS or loopback JWKS URL for RS256 API OIDC/JWT validation; cached with last-good fallback", .sensitive = false },
    .{ .name = "ZCODE_API_OIDC_JWKS_CACHE_TTL_SECONDS", .category = .zcode_config, .description = "TTL for the cached API OIDC JWKS URL response", .sensitive = false },
    .{ .name = "ZCODE_DAEMON_ROLE", .category = .zcode_config, .description = "Role assigned to valid daemon bearer-token requests: none, viewer, auditor, editor, owner", .sensitive = false },
    .{ .name = "ZCODE_TELEMETRY", .category = .zcode_config, .description = "Override the telemetry toggle on unmanaged workstations: off (default) or on; managed config wins when present", .sensitive = false },
    .{ .name = "ZCODE_MANAGED_CONFIG", .category = .zcode_config, .description = "Path to an administrator-managed config (locks fleet policy keys above the user's ~/.zcode/config.toml)", .sensitive = false },
    .{ .name = "ZCODE_KEYCHAIN_BACKEND", .category = .zcode_config, .description = "Force a specific keychain backend (macos|secret_tool|windows_dpapi|file) instead of OS detection", .sensitive = false },
    .{ .name = "ZCODE_SMALL_FAST_MODEL", .category = .zcode_config, .description = "Cheap small-fast model for background work like compaction summaries; bare id or provider/model; falls back to the preprocessor model then the active model", .sensitive = false },
    .{ .name = "ZCODE_DEBUG_INPUT", .category = .zcode_config, .description = "Path to a file that receives raw terminal input bytes for debugging; unset to disable", .sensitive = false },
    .{ .name = "ZCODE_TRANSCRIPT_CLASSIFIER", .category = .zcode_config, .description = "Truthy: run the handoff safety classifier on a sub-agent's output in auto mode and prepend a SECURITY WARNING when flagged", .sensitive = false },
    .{ .name = "CLAUDE_CODE_COORDINATOR_MODE", .category = .zcode_config, .description = "Truthy: run the top-level session as a swarm coordinator (orchestrator persona, delegates all engineering work to AgentRun workers)", .sensitive = false },
    .{ .name = "CLAUDE_CODE_EFFORT_LEVEL", .category = .zcode_config, .description = "Override the reasoning-effort level for the session (low/medium/high/max, or auto/unset to clear); wins over the persisted /effort setting", .sensitive = false },
    .{ .name = "CLAUDE_CODE_SYNTAX_HIGHLIGHT", .category = .zcode_config, .description = "Diff-content syntax highlighting toggle; on by default, set to a falsy value (0/false/no/off) to render diff code lines without language colouring", .sensitive = false },
    .{ .name = "CLAUDE_CODE_TMUX_TRUECOLOR", .category = .zcode_config, .description = "Set (any value) to skip the under-tmux truecolor->256 palette clamp; use only if your tmux is configured with `terminal-overrides ,*:Tc` so truecolor passes through", .sensitive = false },
    .{ .name = "CLAUDE_CODE_AUTO_COMPACT_WINDOW", .category = .zcode_config, .description = "Clamp the effective context window (tokens) used by the auto-compaction buffer model; for testing/tuning the autocompact trigger", .sensitive = false },
    .{ .name = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", .category = .zcode_config, .description = "Percent (0-100) of the effective window at which auto-compaction triggers, capped at the default buffer threshold; for testing", .sensitive = false },
    .{ .name = "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE", .category = .zcode_config, .description = "Force the absolute-token blocking limit (tokens) for the context warning UI; for testing", .sensitive = false },
    .{ .name = "USE_API_CLEAR_TOOL_RESULTS", .category = .zcode_config, .description = "Truthy: opt in to native Anthropic context-management clearing of read-tool results (clear_tool_uses); requires the matching anthropic-beta token", .sensitive = false },
    .{ .name = "USE_API_CLEAR_TOOL_USES", .category = .zcode_config, .description = "Truthy: opt in to native Anthropic context-management clearing of tool uses (excluding write tools); requires the matching anthropic-beta token", .sensitive = false },
    .{ .name = "API_MAX_INPUT_TOKENS", .category = .zcode_config, .description = "Trigger threshold (input tokens) for native API context-management clearing; default 180000", .sensitive = false },
    .{ .name = "API_TARGET_INPUT_TOKENS", .category = .zcode_config, .description = "Keep target (input tokens) after native API context-management clearing; default 40000", .sensitive = false },

    // ── XDG base dirs ─────────────────────────────────────────────
    .{ .name = "XDG_CONFIG_HOME", .category = .xdg, .description = "Config directory root (default: ~/.config)", .sensitive = false },
    .{ .name = "XDG_DATA_HOME", .category = .xdg, .description = "Data directory root (default: ~/.local/share)", .sensitive = false },
    .{ .name = "XDG_CACHE_HOME", .category = .xdg, .description = "Cache directory root (default: ~/.cache)", .sensitive = false },
    .{ .name = "XDG_STATE_HOME", .category = .xdg, .description = "State directory root (default: ~/.local/state)", .sensitive = false },

    // ── System conventions ────────────────────────────────────────
    .{ .name = "HOME", .category = .system, .description = "User home directory (POSIX)", .sensitive = false },
    .{ .name = "NO_COLOR", .category = .system, .description = "Any non-empty value disables ANSI colour (https://no-color.org)", .sensitive = false },
    .{ .name = "FORCE_COLOR", .category = .system, .description = "FORCE_COLOR=0 disables colour (treated like NO_COLOR); other values are a force-on hint", .sensitive = false },
    .{ .name = "COLORTERM", .category = .system, .description = "truecolor/24bit advertises 24-bit colour support; drives the base terminal colour level", .sensitive = false },
    .{ .name = "TERM", .category = .system, .description = "Terminal type; a *-256color value selects the 256-colour base level and feeds capability detection", .sensitive = false },
    .{ .name = "TERM_PROGRAM", .category = .system, .description = "Terminal emulator identity (iTerm.app/vscode/ghostty/...); used for colour-level boost and capability detection", .sensitive = false },
    .{ .name = "TMUX", .category = .system, .description = "Set by tmux itself; triggers the truecolor->256 palette clamp so backgrounds render correctly through tmux", .sensitive = false },
    .{ .name = "NO_HYPERLINK", .category = .system, .description = "Any non-empty value disables OSC 8 terminal hyperlink escapes", .sensitive = false },
    .{ .name = "NO_PROXY", .category = .system, .description = "Comma-separated hosts that should bypass HTTP(S)_PROXY (inherited by curl-based fetches)", .sensitive = false },
    .{ .name = "HTTP_PROXY", .category = .system, .description = "Proxy URL for plaintext HTTP requests, inherited by every curl-based fetch (provider HTTP, MCP HTTP, web/http_request tools, marketplace, updater)", .sensitive = false },
    .{ .name = "HTTPS_PROXY", .category = .system, .description = "Proxy URL for HTTPS requests, inherited by every curl-based fetch (same set of call sites as HTTP_PROXY)", .sensitive = false },
    .{ .name = "CURL_CA_BUNDLE", .category = .system, .description = "Path to a CA bundle curl uses to verify TLS certificates; lets corporate MITM proxies trust the inspected certs", .sensitive = false },
    .{ .name = "SSL_CERT_FILE", .category = .system, .description = "Path to a CA bundle file (OpenSSL convention); curl honors this when CURL_CA_BUNDLE is unset", .sensitive = false },
    .{ .name = "NODE_EXTRA_CA_CERTS", .category = .system, .description = "Additional CA certs file (Node.js convention); diagnostic display only -- curl does not honor this directly, but operators set it for sibling tools", .sensitive = false },
    .{ .name = "REDUCE_MOTION", .category = .system, .description = "Any non-empty value disables animations (same effect as ZCODE_REDUCE_MOTION)", .sensitive = false },
    .{ .name = "PATH", .category = .system, .description = "Searched when launching subprocesses (shell tool, MCP servers)", .sensitive = false },
    .{ .name = "PATHEXT", .category = .system, .description = "Windows-only: executable-extension search list used by zcode's PATH-lookup helper", .sensitive = false },
};

const display_safe = @import("display_safe.zig");

/// Re-export of `display_safe.sanitize` so existing tests that pin
/// the helper name keep working. New callers should import
/// `core/display_safe.zig` directly.
fn sanitizeEnvValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return display_safe.sanitize(allocator, value);
}

/// Render the full env-registry as a plain-text table. Caller owns the
/// returned slice. Sensitive values are shown as `[REDACTED]` when set,
/// `(unset)` otherwise; non-sensitive values render their actual value
/// after sanitizing any C0 control bytes (see sanitizeEnvValue).
pub fn renderTable(allocator: std.mem.Allocator) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // Group by category for readability.
    const categories = [_]EnvEntry.Category{ .provider_key, .provider_endpoint, .zcode_config, .xdg, .system };
    for (categories) |cat| {
        try w.print("── {s} ──\n", .{cat.label()});
        for (entries) |entry| {
            if (entry.category != cat) continue;
            const raw = @import("env.zig").getenv(entry.name);
            var sanitized: ?[]u8 = null;
            defer if (sanitized) |s| allocator.free(s);
            const value_display = blk: {
                if (raw == null or raw.?.len == 0) break :blk "(unset)";
                if (entry.sensitive) break :blk "[REDACTED]";
                sanitized = try sanitizeEnvValue(allocator, raw.?);
                break :blk sanitized.?;
            };
            try w.print("  {s: <30} {s}\n    {s}\n", .{ entry.name, value_display, entry.description });
        }
        try w.writeAll("\n");
    }
    var list = out.toArrayList();
    return list.toOwnedSlice(allocator);
}

const testing = std.testing;

test "sanitizeEnvValue escapes newlines, ESC, DEL" {
    const alloc = testing.allocator;

    const plain = try sanitizeEnvValue(alloc, "http://127.0.0.1:11434");
    defer alloc.free(plain);
    try testing.expectEqualStrings("http://127.0.0.1:11434", plain);

    const with_newline = try sanitizeEnvValue(alloc, "evil\nhack");
    defer alloc.free(with_newline);
    try testing.expectEqualStrings("evil\\x0ahack", with_newline);

    const with_esc = try sanitizeEnvValue(alloc, "red\x1b[31m");
    defer alloc.free(with_esc);
    try testing.expectEqualStrings("red\\x1b[31m", with_esc);

    const with_del = try sanitizeEnvValue(alloc, "a\x7fb");
    defer alloc.free(with_del);
    try testing.expectEqualStrings("a\\x7fb", with_del);

    // High-bit UTF-8 bytes pass through unchanged.
    const unicode = try sanitizeEnvValue(alloc, "caf\xc3\xa9");
    defer alloc.free(unicode);
    try testing.expectEqualStrings("caf\xc3\xa9", unicode);
}

test "registry documents every ZCODE_* / NO_* / proxy env var the code reads" {
    // Every env var referenced from production code (not tests / fuzz /
    // doc comments) must appear in `entries` so `zcode --list-env` stays
    // authoritative. When adding a new getenv, add a matching entry here
    // or this test fails in CI.
    const expected = [_][]const u8{
        // System.
        "NO_COLOR",
        "NO_HYPERLINK",
        "NO_PROXY",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "CURL_CA_BUNDLE",
        "SSL_CERT_FILE",
        "NODE_EXTRA_CA_CERTS",
        "PATH",
        "PATHEXT",
        "HOME",
        "FORCE_COLOR",
        "COLORTERM",
        "TERM",
        "TERM_PROGRAM",
        "TMUX",
        // ZCODE_.
        "ZCODE_VERBOSE",
        "ZCODE_SESSION_KEY",
        "ZCODE_DAEMON_TOKEN",
        "ZCODE_SESSIONS_DIR",
        "ZCODE_SESSION_KIND",
        "ZCODE_SESSION_LOG",
        "ZCODE_SESSION_NAME",
        "ZCODE_FILE_READ_MAX_TOKENS",
        "ZCODE_FILE_READ_MAX_BYTES",
        "ZCODE_FILE_WRITE_MAX_BYTES",
        "ZCODE_SKIP_READ_BEFORE_EDIT",
        "ZCODE_ALLOW_BASH_BANNED",
        "ZCODE_BASH_DEFAULT_TIMEOUT_MS",
        "ZCODE_BASH_MAX_TIMEOUT_MS",
        "ZCODE_MAX_LINE_BYTES",
        "ZCODE_DEBUG_SCROLL",
        "ZCODE_DEBUG_INPUT",
        "ZCODE_TRANSCRIPT_CLASSIFIER",
        "ZCODE_MOCK_RESPONSE",
        "ZCODE_MOCK_RESPONSES",
        "ZCODE_OVERRIDE_DATE",
        "ZCODE_UPDATE_MANIFEST_URL",
        "ZCODE_UPDATE_PINNED_VERSION",
        "ZCODE_ALLOW_UNSIGNED_UPDATE",
        "ZCODE_UPDATE_REQUIRE_SIGNATURE",
        "ZCODE_REDUCE_MOTION",
        "ZCODE_API_PROFILE",
        "ZCODE_API_ROLE",
        "ZCODE_API_AUTH_REQUIRED",
        "ZCODE_API_BEARER_TOKEN",
        "ZCODE_API_OIDC_ISSUER",
        "ZCODE_API_OIDC_AUDIENCE",
        "ZCODE_API_OIDC_HS256_SECRET",
        "ZCODE_API_OIDC_JWKS_JSON",
        "ZCODE_API_OIDC_JWKS_FILE",
        "ZCODE_API_OIDC_JWKS_URL",
        "ZCODE_API_OIDC_JWKS_CACHE_TTL_SECONDS",
        "ZCODE_DAEMON_ROLE",
        "ZCODE_TELEMETRY",
        "ZCODE_MANAGED_CONFIG",
        "ZCODE_KEYCHAIN_BACKEND",
        "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
        "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
        "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE",
        "CLAUDE_CODE_TMUX_TRUECOLOR",
        "CLAUDE_CODE_EFFORT_LEVEL",
        "USE_API_CLEAR_TOOL_RESULTS",
        "USE_API_CLEAR_TOOL_USES",
        "API_MAX_INPUT_TOKENS",
        "API_TARGET_INPUT_TOKENS",
    };

    for (expected) |name| {
        var found = false;
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("env var {s} is read from code but not listed in env_registry.zig\n", .{name});
            try testing.expect(false);
        }
    }
}

test "renderTable covers every category and redacts sensitive values" {
    const alloc = testing.allocator;
    const out = try renderTable(alloc);
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "provider API keys") != null);
    try testing.expect(std.mem.indexOf(u8, out, "XDG base dirs") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ZCODE_SESSION_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, out, "OPENAI_API_KEY") != null);

    // Simulate a set sensitive value: ZCODE_SESSION_KEY commonly set in
    // real envs. If it IS set in the test env, we should see [REDACTED]
    // and not the actual value.
    if (@import("env.zig").getenv("ZCODE_SESSION_KEY")) |v| {
        if (v.len > 0) {
            try testing.expect(std.mem.indexOf(u8, out, v) == null);
            try testing.expect(std.mem.indexOf(u8, out, "[REDACTED]") != null);
        }
    }
}
