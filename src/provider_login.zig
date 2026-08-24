//! `zcode login` -- provision a model provider interactively.
//!
//! zcode is bring-your-own-key: it ships with no credentials, so a fresh
//! install cannot talk to a model until one of these paths runs. Four are
//! offered because they trade off differently and only the user can pick:
//!
//!   - Anthropic API key   pay-per-token, strongest models
//!   - OpenRouter API key  one key, many providers behind it
//!   - Local model         free and offline via Ollama, weaker
//!   - Browser sign-in     OAuth, no key to copy and paste
//!
//! The browser flow runs OpenRouter's PKCE authorization
//! (https://openrouter.ai/docs/use-cases/oauth-pkce), which exists precisely so
//! third-party tools can mint a user's key without ever seeing their password.
//! Anthropic has no equivalent public OAuth flow for third-party clients -- its
//! supported path for a program like zcode is an API key -- so "sign in with
//! your Claude subscription" is deliberately not offered here rather than
//! faked by impersonating another client.
//!
//! Every path ends the same way: the secret goes to the OS keychain (never
//! config.toml, never argv) and `default_provider` / `default_model` are
//! persisted so the next launch just works.

const std = @import("std");
const std_io = @import("core/std_io.zig");
const keychain = @import("core/keychain.zig");
const config_mod = @import("core/config.zig");
const config_parse = @import("core/config_parse.zig");
const oauth = @import("core/oauth_loopback.zig");
const http_common = @import("providers/common.zig");
const display_safe = @import("core/display_safe.zig");

const http_timeout_ms: u32 = 30_000;

/// How the user wants to authenticate. `null` at the command layer means "ask".
pub const Method = enum {
    anthropic_key,
    openrouter_key,
    local,
    oauth,

    pub fn fromFlag(text: []const u8) ?Method {
        if (std.mem.eql(u8, text, "anthropic")) return .anthropic_key;
        if (std.mem.eql(u8, text, "openrouter")) return .openrouter_key;
        if (std.mem.eql(u8, text, "local")) return .local;
        if (std.mem.eql(u8, text, "oauth") or std.mem.eql(u8, text, "browser")) return .oauth;
        return null;
    }
};

/// The provider defaults each method lands on. `model` is only applied when the
/// user is switching providers -- see `applyDefaults`.
fn defaultsFor(method: Method) struct { provider: []const u8, model: []const u8 } {
    return switch (method) {
        .anthropic_key => .{ .provider = "anthropic", .model = "claude-sonnet-5" },
        .openrouter_key, .oauth => .{ .provider = "openrouter", .model = "anthropic/claude-sonnet-5" },
        .local => .{ .provider = "local", .model = "" },
    };
}

// --- entry point -------------------------------------------------------

pub fn cmdLogin(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    method_in: ?Method,
    writer: anytype,
) !void {
    const method = method_in orelse (try chooseMethod(allocator, writer)) orelse {
        try writer.writeAll("Cancelled. Nothing was changed.\n");
        return;
    };

    switch (method) {
        .anthropic_key => try loginWithKey(allocator, cfg, .anthropic_key, writer),
        .openrouter_key => try loginWithKey(allocator, cfg, .openrouter_key, writer),
        .local => try setupLocal(allocator, cfg, writer),
        .oauth => try loginWithOAuth(allocator, cfg, writer),
    }
}

fn chooseMethod(allocator: std.mem.Allocator, writer: anytype) !?Method {
    try writer.writeAll(
        \\How should zcode reach a model?
        \\
        \\  1  Anthropic API key      pay-per-token from console.anthropic.com
        \\  2  OpenRouter API key     one key, many providers behind it
        \\  3  Local model            free and offline, needs Ollama running
        \\  4  Sign in via browser    OpenRouter OAuth, nothing to paste
        \\
        \\Choose 1-4 (Enter to cancel):
    );
    try writer.writeAll(" ");

    const line = try readLine(allocator, 16) orelse return null;
    defer allocator.free(line);
    const choice = std.mem.trim(u8, line, " \t\r\n");
    if (choice.len == 0) return null;

    if (std.mem.eql(u8, choice, "1")) return .anthropic_key;
    if (std.mem.eql(u8, choice, "2")) return .openrouter_key;
    if (std.mem.eql(u8, choice, "3")) return .local;
    if (std.mem.eql(u8, choice, "4")) return .oauth;

    try writer.print("Not one of 1-4. Nothing was changed.\n", .{});
    return null;
}

// --- API key paths -----------------------------------------------------

fn loginWithKey(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    method: Method,
    writer: anytype,
) !void {
    const defaults = defaultsFor(method);
    const where = if (method == .anthropic_key)
        "https://console.anthropic.com/settings/keys"
    else
        "https://openrouter.ai/keys";

    try writer.print("Paste your {s} API key (get one at {s}).\n", .{ defaults.provider, where });
    try writer.writeAll("The key is stored in your OS keychain, not in any config file.\n");
    try writer.writeAll("key: ");

    // Read with terminal echo off where we can: an API key scrolled into the
    // terminal outlives the session in scrollback and in any recording.
    const secret_line = try readLineNoEcho(allocator, 4096) orelse {
        try writer.writeAll("\nNo key entered. Nothing was changed.\n");
        return;
    };
    defer {
        // Best effort: do not leave the plaintext key sitting in freed heap.
        @memset(secret_line, 0);
        allocator.free(secret_line);
    }
    try writer.writeAll("\n");

    const secret = std.mem.trim(u8, secret_line, " \t\r\n");
    if (secret.len == 0) {
        try writer.writeAll("No key entered. Nothing was changed.\n");
        return;
    }

    try storeAndVerify(allocator, defaults.provider, secret, writer);
    try applyDefaults(allocator, cfg, defaults.provider, defaults.model, writer);
    try writer.print("\nDone. Try it with: zcode run \"say hi\"\n", .{});
}

/// Write the secret to the keychain and read it straight back.
///
/// The read-back is not ceremony. A macOS `security` argv bug once stored the
/// keychain's own path in place of every secret while still exiting 0, and the
/// only symptom was an unusable credential much later, in a completely
/// different command. Verifying here turns that class of failure into an
/// immediate, local error.
fn storeAndVerify(
    allocator: std.mem.Allocator,
    provider: []const u8,
    secret: []const u8,
    writer: anytype,
) !void {
    keychain.set(allocator, provider, secret) catch |err| {
        try writer.print("error: could not store the key in the keychain: {s}\n", .{@errorName(err)});
        if (err == keychain.Error.KeychainLocked) {
            try writer.print("  {s}\n", .{keychain.keychain_locked_hint});
        }
        return err;
    };

    const read_back = keychain.get(allocator, provider) catch |err| {
        try writer.print("error: key was stored but could not be read back: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        @memset(read_back, 0);
        allocator.free(read_back);
    }

    if (!std.mem.eql(u8, read_back, secret)) {
        try writer.writeAll("error: the keychain returned a different value than was stored.\n");
        try writer.writeAll("  Refusing to report success on a credential that will not work.\n");
        return error.KeychainRoundTripMismatch;
    }

    try writer.print("Stored {s} key in the keychain (verified).\n", .{provider});
}

// --- OAuth path (OpenRouter PKCE) --------------------------------------

fn loginWithOAuth(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    writer: anytype,
) !void {
    const defaults = defaultsFor(.oauth);

    var pkce = try oauth.generatePkce(allocator);
    defer pkce.deinit(allocator);

    const callback_url = try oauth.callbackUrlAlloc(allocator);
    defer allocator.free(callback_url);

    const callback_encoded = try oauth.urlEncodeAlloc(allocator, callback_url);
    defer allocator.free(callback_encoded);

    const auth_url = try buildAuthUrl(allocator, callback_encoded, pkce.challenge);
    defer allocator.free(auth_url);

    try writer.writeAll("Opening your browser to sign in with OpenRouter.\n");
    try writer.print("If it does not open, visit:\n  {s}\n\n", .{auth_url});
    try writer.print("Waiting for the redirect back to {s} ...\n", .{callback_url});

    var callback = oauth.awaitCallback(allocator, auth_url) catch |err| {
        switch (err) {
            oauth.Error.CallbackTimeout => try writer.writeAll(
                "error: timed out waiting for the browser redirect. Nothing was changed.\n",
            ),
            oauth.Error.BrowserOpenFailed => try writer.print(
                "error: could not launch a browser. Open the URL above by hand and rerun.\n",
                .{},
            ),
            else => try writer.print("error: sign-in failed: {s}\n", .{@errorName(err)}),
        }
        return err;
    };
    defer callback.deinit();

    // A provider that refuses reports it in the query, not by hanging up.
    if (try callback.paramDecoded("error")) |provider_error| {
        defer allocator.free(provider_error);
        callback.respond("zcode sign-in failed. Return to the terminal for details.");
        const safe = try display_safe.sanitize(allocator, provider_error);
        defer allocator.free(safe);
        try writer.print("error: OpenRouter declined the sign-in: {s}\n", .{safe});
        return error.OAuthProviderError;
    }

    const code = (try callback.paramDecoded("code")) orelse {
        callback.respond("zcode sign-in failed: no authorization code.");
        try writer.writeAll("error: the redirect carried no authorization code.\n");
        return error.OAuthMissingCode;
    };
    defer {
        @memset(code, 0);
        allocator.free(code);
    }

    callback.respond("zcode is signed in. You can close this tab and return to the terminal.");

    try writer.writeAll("Exchanging the authorization code for a key ...\n");
    const key = exchangeCodeForKey(allocator, code, pkce.verifier) catch |err| {
        try writer.print("error: the code exchange failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer {
        @memset(key, 0);
        allocator.free(key);
    }

    try storeAndVerify(allocator, defaults.provider, key, writer);
    try applyDefaults(allocator, cfg, defaults.provider, defaults.model, writer);
    try writer.print("\nDone. Try it with: zcode run \"say hi\"\n", .{});
}

/// Build OpenRouter's authorization URL. `callback_encoded` must already be
/// percent-encoded: it is a full URL nested inside a query parameter, so its
/// own `:` and `/` would otherwise terminate the parameter early.
fn buildAuthUrl(allocator: std.mem.Allocator, callback_encoded: []const u8, challenge: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://openrouter.ai/auth?callback_url={s}&code_challenge={s}&code_challenge_method=S256",
        .{ callback_encoded, challenge },
    );
}

/// Trade the one-time authorization code for a real API key. The verifier
/// proves we are the same client that started the flow; it never left this
/// machine, so a code intercepted from the redirect is useless on its own.
fn exchangeCodeForKey(allocator: std.mem.Allocator, code: []const u8, verifier: []const u8) ![]u8 {
    var body = std_io.StringBuilder.init(allocator);
    defer body.deinit();
    try body.writer().print(
        "{{\"code\":\"{f}\",\"code_verifier\":\"{f}\",\"code_challenge_method\":\"S256\"}}",
        .{ std.json.fmt(code, .{}), std.json.fmt(verifier, .{}) },
    );

    const headers = [_][]const u8{"Content-Type: application/json"};
    const raw = try http_common.callHttp(
        allocator,
        .POST,
        "https://openrouter.ai/api/v1/auth/keys",
        &headers,
        body.items(),
        http_timeout_ms,
    );
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch
        return error.OAuthMalformedTokenResponse;
    defer parsed.deinit();

    if (parsed.value != .object) return error.OAuthMalformedTokenResponse;
    const key_value = parsed.value.object.get("key") orelse return error.OAuthMissingKeyInResponse;
    if (key_value != .string or key_value.string.len == 0) return error.OAuthMissingKeyInResponse;
    return allocator.dupe(u8, key_value.string);
}

// --- local model path --------------------------------------------------

fn setupLocal(allocator: std.mem.Allocator, cfg: *const config_mod.Config, writer: anytype) !void {
    const base_url = if (cfg.local_base_url.len > 0) cfg.local_base_url else "http://127.0.0.1:11434";
    const tags_url = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{base_url});
    defer allocator.free(tags_url);

    try writer.print("Looking for a local model server at {s} ...\n", .{base_url});

    const raw = http_common.callHttp(allocator, .GET, tags_url, &.{}, null, 5_000) catch {
        try writer.print(
            \\Nothing is listening at {s}.
            \\
            \\zcode's local provider speaks the Ollama API. To use it:
            \\  1. Install Ollama:  brew install ollama
            \\  2. Start it:        ollama serve
            \\  3. Pull a model:    ollama pull qwen2.5-coder:7b
            \\  4. Rerun:           zcode login --local
            \\
            \\Point elsewhere with `local_base_url` in ~/.zcode/config.toml if your
            \\server runs on another host or port.
            \\
        , .{base_url});
        return;
    };
    defer allocator.free(raw);

    const models = parseOllamaModels(allocator, raw) catch &[_][]const u8{};
    defer {
        for (models) |m| allocator.free(m);
        if (models.len > 0) allocator.free(models);
    }

    if (models.len == 0) {
        try writer.writeAll(
            \\The server answered but has no models pulled yet.
            \\  Pull one, e.g.:  ollama pull qwen2.5-coder:7b
            \\  Then rerun:      zcode login --local
            \\
        );
        return;
    }

    try writer.writeAll("Available local models:\n");
    for (models, 0..) |m, i| {
        const safe = try display_safe.sanitize(allocator, m);
        defer allocator.free(safe);
        try writer.print("  {d}  {s}\n", .{ i + 1, safe });
    }
    try writer.print("Choose 1-{d} (Enter for the first):", .{models.len});
    try writer.writeAll(" ");

    var pick: usize = 0;
    if (try readLine(allocator, 16)) |line| {
        defer allocator.free(line);
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len > 0) {
            const n = std.fmt.parseInt(usize, trimmed, 10) catch 0;
            if (n >= 1 and n <= models.len) {
                pick = n - 1;
            } else {
                try writer.writeAll("Not in range; using the first.\n");
            }
        }
    }

    try writer.writeAll("Local models need no API key.\n");
    try applyDefaults(allocator, cfg, "local", models[pick], writer);
    try writer.print("\nDone. Try it with: zcode run \"say hi\"\n", .{});
}

/// Pull the model names out of an Ollama `/api/tags` payload.
/// Caller owns both the slice and every name in it.
fn parseOllamaModels(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return &[_][]const u8{};
    const models_value = parsed.value.object.get("models") orelse return &[_][]const u8{};
    if (models_value != .array) return &[_][]const u8{};

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |m| allocator.free(m);
        out.deinit(allocator);
    }

    for (models_value.array.items) |entry| {
        if (entry != .object) continue;
        const name = entry.object.get("name") orelse continue;
        if (name != .string or name.string.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, name.string));
    }

    return out.toOwnedSlice(allocator);
}

// --- shared tail -------------------------------------------------------

/// Persist `default_provider`, and `default_model` only when the provider is
/// actually changing. Someone who deliberately set `claude-haiku-4-5` and then
/// re-runs login for the same provider should keep their choice; someone
/// switching from Anthropic to OpenRouter must not be left pointing at a model
/// id the new provider has never heard of.
fn applyDefaults(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider: []const u8,
    model: []const u8,
    writer: anytype,
) !void {
    const switching = !std.mem.eql(u8, cfg.default_provider, provider);

    config_parse.persistUserConfigField(allocator, "default_provider", provider) catch |err| {
        try writer.print("warning: could not persist default_provider: {s}\n", .{@errorName(err)});
    };

    if (model.len > 0 and (switching or cfg.default_model.len == 0)) {
        config_parse.persistUserConfigField(allocator, "default_model", model) catch |err| {
            try writer.print("warning: could not persist default_model: {s}\n", .{@errorName(err)});
        };
        try writer.print("Default is now {s}/{s}.\n", .{ provider, model });
    } else {
        try writer.print("Default is now {s}/{s} (model unchanged).\n", .{ provider, cfg.default_model });
    }
}

// --- terminal input ----------------------------------------------------

fn readLine(allocator: std.mem.Allocator, max: usize) !?[]u8 {
    return std_io.stdinReader().readUntilDelimiterOrEofAlloc(allocator, '\n', max) catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLong,
        else => return err,
    };
}

/// Read one line with terminal echo suppressed, restoring the previous mode on
/// every exit path. Falls back to an echoing read when stdin is not a terminal
/// (a pipe, CI), where there is no echo to suppress anyway.
fn readLineNoEcho(allocator: std.mem.Allocator, max: usize) !?[]u8 {
    const fd = std.Io.File.stdin().handle;
    const saved = std.posix.tcgetattr(fd) catch return readLine(allocator, max);

    var quiet = saved;
    quiet.lflag.ECHO = false;
    std.posix.tcsetattr(fd, .NOW, quiet) catch return readLine(allocator, max);
    defer std.posix.tcsetattr(fd, .NOW, saved) catch {};

    return readLine(allocator, max);
}

// --- tests -------------------------------------------------------------

const testing = std.testing;

test "method flags map to the documented spellings" {
    try testing.expectEqual(Method.anthropic_key, Method.fromFlag("anthropic").?);
    try testing.expectEqual(Method.openrouter_key, Method.fromFlag("openrouter").?);
    try testing.expectEqual(Method.local, Method.fromFlag("local").?);
    try testing.expectEqual(Method.oauth, Method.fromFlag("oauth").?);
    // `browser` is accepted because that is what the menu calls this option.
    try testing.expectEqual(Method.oauth, Method.fromFlag("browser").?);
    try testing.expect(Method.fromFlag("anthropic-key") == null);
    try testing.expect(Method.fromFlag("") == null);
}

test "every method's default provider is one providers status knows" {
    // A default that no adapter recognizes would persist a config the next
    // launch cannot resolve, stranding the user right after a "Done." message.
    const known = [_][]const u8{ "anthropic", "openrouter", "local" };
    for ([_]Method{ .anthropic_key, .openrouter_key, .local, .oauth }) |m| {
        const d = defaultsFor(m);
        var found = false;
        for (known) |k| {
            if (std.mem.eql(u8, k, d.provider)) found = true;
        }
        try testing.expect(found);
    }
}

test "openrouter defaults carry a provider-qualified model id" {
    // OpenRouter routes on `vendor/model`; a bare `claude-sonnet-5` 404s there.
    const d = defaultsFor(.openrouter_key);
    try testing.expect(std.mem.indexOfScalar(u8, d.model, '/') != null);
    try testing.expectEqualStrings(defaultsFor(.oauth).model, d.model);

    // Anthropic's own API takes the bare id, and must NOT be qualified.
    try testing.expect(std.mem.indexOfScalar(u8, defaultsFor(.anthropic_key).model, '/') == null);
}

test "parseOllamaModels pulls names out of an /api/tags payload" {
    const raw =
        \\{"models":[{"name":"qwen2.5-coder:7b","size":1},{"name":"llama3:latest"}]}
    ;
    const models = try parseOllamaModels(testing.allocator, raw);
    defer {
        for (models) |m| testing.allocator.free(m);
        testing.allocator.free(models);
    }
    try testing.expectEqual(@as(usize, 2), models.len);
    try testing.expectEqualStrings("qwen2.5-coder:7b", models[0]);
    try testing.expectEqualStrings("llama3:latest", models[1]);
}

test "parseOllamaModels tolerates junk instead of crashing" {
    // A server that is not Ollama can answer 200 with anything at all.
    for ([_][]const u8{ "{}", "[]", "{\"models\":\"nope\"}", "{\"models\":[{},{\"name\":123}]}" }) |raw| {
        const models = try parseOllamaModels(testing.allocator, raw);
        defer {
            for (models) |m| testing.allocator.free(m);
            if (models.len > 0) testing.allocator.free(models);
        }
        try testing.expectEqual(@as(usize, 0), models.len);
    }
}

test "auth url nests the encoded callback and advertises S256" {
    const callback = try oauth.callbackUrlAlloc(testing.allocator);
    defer testing.allocator.free(callback);
    const encoded = try oauth.urlEncodeAlloc(testing.allocator, callback);
    defer testing.allocator.free(encoded);

    const url = try buildAuthUrl(testing.allocator, encoded, "CHALLENGE");
    defer testing.allocator.free(url);

    try testing.expect(std.mem.startsWith(u8, url, "https://openrouter.ai/auth?"));
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge=CHALLENGE") != null);

    // The nested callback must be escaped: a raw "://" inside the query would
    // cut the parameter short and the redirect would never come home.
    try testing.expect(std.mem.indexOf(u8, url, "callback_url=http://") == null);
    try testing.expect(std.mem.indexOf(u8, url, "callback_url=http%3A%2F%2F127.0.0.1") != null);
}

test "auth url never carries the verifier" {
    // The whole point of PKCE: only the challenge may travel to the provider.
    // Leaking the verifier into the URL would make the exchange forgeable by
    // anyone who saw it in browser history or a proxy log.
    var pkce = try oauth.generatePkce(testing.allocator);
    defer pkce.deinit(testing.allocator);

    const url = try buildAuthUrl(testing.allocator, "cb", pkce.challenge);
    defer testing.allocator.free(url);
    try testing.expect(std.mem.indexOf(u8, url, pkce.verifier) == null);
}
