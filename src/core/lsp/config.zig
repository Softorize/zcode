//! LSP server configuration: built-in defaults merged with plugin-sourced
//! overrides (parity lsp-07, hybrid).
//!
//! INTENTIONAL DIVERGENCE from the reference. The reference sources LSP servers
//! *exclusively* from plugins (`config.ts:getAllLspServers`). zcode keeps a
//! built-in default table so zls/pyright/gopls/etc. just work out of the box,
//! and treats plugin config as an *override* layer. Rationale: our zero-config
//! UX is a strength worth preserving; forcing every user to install a plugin to
//! get Zig LSP would be a regression. Plugins win on an extension collision
//! (matching the reference's `Object.assign` precedence), so a plugin can still
//! fully replace a built-in server for an extension it cares about.
//!
//! A plugin manifest may carry an optional `lspServers` array, e.g.:
//!
//!   "lspServers": [
//!     { "name": "vue-language-server",
//!       "command": "vue-language-server",
//!       "args": ["--stdio"],
//!       "env": { "FOO": "bar" },
//!       "workspaceFolder": "/abs/proj",
//!       "extensionToLanguage": { ".vue": "vue" },
//!       "initializationOptions": { "typescript": { "tsdk": "/x" } },
//!       "startupTimeout": 45000,
//!       "maxRestarts": 5 }
//!   ]
//!
//! `LspServerConfig.parseManifestArray` is the pure parser plugins.zig calls; it
//! does no IO so it stays unit-testable. `getAllServers` is the one IO entry
//! point: it reads the plugin list and merges it over the defaults.

const std = @import("std");
const rt = @import("zcode_runtime");

/// One `KEY=value` environment override for a server (mirrors the env-pair
/// shape used by mcp_config.ServerConfig). Both fields are dup-owned.
pub const EnvEntry = struct {
    key: []u8,
    value: []u8,
};

/// One extension -> languageId mapping (e.g. ".vue" -> "vue"). Both fields are
/// dup-owned. Kept as a small struct rather than a hashmap so a config is a
/// flat, cheaply-copyable value.
pub const ExtLang = struct {
    ext: []u8,
    language: []u8,
};

/// A fully-resolved language-server configuration. All owned slices are
/// dup-owned and released by `deinit`. A built-in default and a plugin-sourced
/// override share this one shape so the merge is uniform.
pub const LspServerConfig = struct {
    /// Server name / binary, e.g. "zls" or "vue-language-server".
    name: []u8,
    /// The command to spawn. Defaults to `name` when a plugin omits it.
    command: []u8,
    /// argv after the command, e.g. ["--stdio"]. Dup-owned (each element + the
    /// slice).
    args: [][]u8,
    /// Extra environment overrides spliced over the inherited environment.
    env: []EnvEntry,
    /// Optional explicit workspace-folder path. Null -> the manager uses the
    /// caller's cwd.
    workspace_folder: ?[]u8,
    /// ext -> languageId table for this server. Drives both the manager's
    /// extension routing map and the `languageId` carried in didOpen.
    extension_to_language: []ExtLang,
    /// Opaque `initializationOptions` JSON, stored as a validated JSON string and
    /// spliced into the `initialize` params (required by vue-language-server).
    /// Null when the plugin/default does not supply any.
    initialization_options_json: ?[]u8,
    /// Handshake startup timeout in ms (server_instance.startup_timeout_ms).
    startup_timeout_ms: i64,
    /// Crash-recovery cap (server_instance.max_restarts).
    max_restarts: u32,

    pub fn deinit(self: *LspServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.command);
        for (self.args) |a| allocator.free(a);
        if (self.args.len > 0) allocator.free(self.args);
        for (self.env) |*e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        if (self.env.len > 0) allocator.free(self.env);
        if (self.workspace_folder) |w| allocator.free(w);
        for (self.extension_to_language) |*el| {
            allocator.free(el.ext);
            allocator.free(el.language);
        }
        if (self.extension_to_language.len > 0) allocator.free(self.extension_to_language);
        if (self.initialization_options_json) |j| allocator.free(j);
        self.* = undefined;
    }

    /// The languageId this config maps `ext` to, or null when the config does
    /// not cover that extension.
    pub fn languageForExt(self: *const LspServerConfig, ext: []const u8) ?[]const u8 {
        for (self.extension_to_language) |el| {
            if (std.mem.eql(u8, el.ext, ext)) return el.language;
        }
        return null;
    }

    /// Parse a plugin manifest's `lspServers` array (the `std.json.Value` for
    /// that key) into a list of configs. Pure: no IO. A malformed or absent
    /// value yields an empty slice (a broken `lspServers` must not break plugin
    /// loading). Entries with no resolvable `name` are skipped. `command`
    /// defaults to `name`, `args` defaults to `["--stdio"]`, the timeout/cap
    /// default to the built-in defaults.
    pub fn parseManifestArray(
        allocator: std.mem.Allocator,
        value: ?std.json.Value,
    ) ![]LspServerConfig {
        const v = value orelse return &.{};
        if (v != .array) return &.{};

        var out = std.array_list.Managed(LspServerConfig).init(allocator);
        errdefer {
            for (out.items) |*c| c.deinit(allocator);
            out.deinit();
        }

        for (v.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const name = jsonString(obj, "name") orelse continue;
            if (name.len == 0) continue;

            const cfg = try buildFromManifestObject(allocator, obj, name);
            try out.append(cfg);
        }
        return out.toOwnedSlice();
    }
};

/// Build one `LspServerConfig` from a manifest `lspServers` entry object.
fn buildFromManifestObject(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    name: []const u8,
) !LspServerConfig {
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const command_str = jsonString(obj, "command") orelse name;
    const owned_command = try allocator.dupe(u8, command_str);
    errdefer allocator.free(owned_command);

    const args = try parseArgs(allocator, obj.get("args"));
    errdefer freeArgs(allocator, args);

    const env = try parseEnv(allocator, obj.get("env"));
    errdefer freeEnv(allocator, env);

    const workspace_folder = if (jsonString(obj, "workspaceFolder")) |w|
        try allocator.dupe(u8, w)
    else
        null;
    errdefer if (workspace_folder) |w| allocator.free(w);

    const ext_lang = try parseExtensionToLanguage(allocator, obj.get("extensionToLanguage"));
    errdefer freeExtLang(allocator, ext_lang);

    // initializationOptions is opaque JSON; re-serialize it back to a validated
    // string so it can be spliced into the init params without re-injection.
    const init_opts = try parseInitializationOptions(allocator, obj.get("initializationOptions"));
    errdefer if (init_opts) |j| allocator.free(j);

    const startup_timeout = jsonI64(obj, "startupTimeout") orelse DEFAULT_STARTUP_TIMEOUT_MS;
    const max_restarts = jsonU32(obj, "maxRestarts") orelse DEFAULT_MAX_RESTARTS;

    return .{
        .name = owned_name,
        .command = owned_command,
        .args = args,
        .env = env,
        .workspace_folder = workspace_folder,
        .extension_to_language = ext_lang,
        .initialization_options_json = init_opts,
        .startup_timeout_ms = startup_timeout,
        .max_restarts = max_restarts,
    };
}

/// Default handshake startup timeout (30s), matching server_instance's
/// REQUEST_TIMEOUT_MS. Defined here so config does not depend on
/// server_instance (avoiding a needless import cycle).
pub const DEFAULT_STARTUP_TIMEOUT_MS: i64 = 30 * 1000;
/// Default crash-recovery cap, matching server_instance's DEFAULT_MAX_RESTARTS.
pub const DEFAULT_MAX_RESTARTS: u32 = 3;

/// One built-in default: an extension, the languageId, and the server binary.
/// Promoted into a full `LspServerConfig` by `defaults`. This is the table
/// lifted from `tools/lsp.zig:detectLanguageServer` plus the languageId map
/// previously inlined in `lsp/manager.zig`.
const DefaultRow = struct {
    ext: []const u8,
    language: []const u8,
    server: []const u8,
};

const default_rows = [_]DefaultRow{
    .{ .ext = ".zig", .language = "zig", .server = "zls" },
    .{ .ext = ".py", .language = "python", .server = "pyright-langserver" },
    .{ .ext = ".ts", .language = "typescript", .server = "typescript-language-server" },
    .{ .ext = ".tsx", .language = "typescriptreact", .server = "typescript-language-server" },
    .{ .ext = ".js", .language = "javascript", .server = "typescript-language-server" },
    .{ .ext = ".jsx", .language = "javascriptreact", .server = "typescript-language-server" },
    .{ .ext = ".go", .language = "go", .server = "gopls" },
    .{ .ext = ".rs", .language = "rust", .server = "rust-analyzer" },
    .{ .ext = ".c", .language = "c", .server = "clangd" },
    .{ .ext = ".h", .language = "c", .server = "clangd" },
    .{ .ext = ".cpp", .language = "cpp", .server = "clangd" },
    .{ .ext = ".hpp", .language = "cpp", .server = "clangd" },
    .{ .ext = ".java", .language = "java", .server = "jdtls" },
    .{ .ext = ".lua", .language = "lua", .server = "lua-language-server" },
};

/// The built-in default server configs, one per distinct server binary. Each
/// default carries `command + ["--stdio"]` args and the `extensionToLanguage`
/// rows that route to it. Returns an owned slice; free with `freeServers`.
pub fn defaults(allocator: std.mem.Allocator) ![]LspServerConfig {
    var out = std.array_list.Managed(LspServerConfig).init(allocator);
    errdefer {
        for (out.items) |*c| c.deinit(allocator);
        out.deinit();
    }

    // Group rows by server name so each distinct binary becomes one config that
    // owns all of its extension rows (e.g. typescript-language-server owns .ts
    // .tsx .js .jsx; clangd owns .c .h .cpp .hpp).
    for (default_rows) |row| {
        // Find an existing config for this server in the accumulator.
        var found: ?*LspServerConfig = null;
        for (out.items) |*c| {
            if (std.mem.eql(u8, c.name, row.server)) {
                found = c;
                break;
            }
        }
        if (found) |cfg| {
            try appendExtLang(allocator, cfg, row.ext, row.language);
        } else {
            const cfg = try buildDefaultConfig(allocator, row);
            try out.append(cfg);
        }
    }
    return out.toOwnedSlice();
}

/// Build a default config for a server with its first extension row. Further
/// rows for the same server are folded in by `appendExtLang`.
fn buildDefaultConfig(allocator: std.mem.Allocator, row: DefaultRow) !LspServerConfig {
    const name = try allocator.dupe(u8, row.server);
    errdefer allocator.free(name);
    const command = try allocator.dupe(u8, row.server);
    errdefer allocator.free(command);

    var args = try allocator.alloc([]u8, 1);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, "--stdio");

    var ext_lang = try allocator.alloc(ExtLang, 1);
    errdefer allocator.free(ext_lang);
    ext_lang[0] = .{
        .ext = try allocator.dupe(u8, row.ext),
        .language = try allocator.dupe(u8, row.language),
    };

    return .{
        .name = name,
        .command = command,
        .args = args,
        .env = &.{},
        .workspace_folder = null,
        .extension_to_language = ext_lang,
        .initialization_options_json = null,
        .startup_timeout_ms = DEFAULT_STARTUP_TIMEOUT_MS,
        .max_restarts = DEFAULT_MAX_RESTARTS,
    };
}

/// Append one ext->language row to an existing config, growing its slice.
fn appendExtLang(allocator: std.mem.Allocator, cfg: *LspServerConfig, ext: []const u8, language: []const u8) !void {
    const new_len = cfg.extension_to_language.len + 1;
    const grown = try allocator.realloc(cfg.extension_to_language, new_len);
    cfg.extension_to_language = grown;
    grown[new_len - 1] = .{
        .ext = try allocator.dupe(u8, ext),
        .language = try allocator.dupe(u8, language),
    };
}

/// All resolved LSP servers: built-in defaults overlaid with plugin-sourced
/// configs. Plugin servers win on an extension collision (the plugin's server
/// takes that extension), matching the reference's `Object.assign` precedence.
/// A plugin server with a brand-new extension is simply added. Returns an owned
/// slice; free with `freeServers`.
///
/// `cwd` is the working directory used to discover plugins (passed through to
/// `plugins.list`). When plugin discovery fails (no plugin dir, malformed
/// manifests already skipped upstream), the defaults are returned unchanged.
pub fn getAllServers(allocator: std.mem.Allocator, cwd: []const u8) ![]LspServerConfig {
    var merged = std.array_list.Managed(LspServerConfig).init(allocator);
    errdefer freeServersList(allocator, &merged);

    const base = try defaults(allocator);
    defer freeServers(allocator, base);
    for (base) |*d| {
        const cloned = try cloneConfig(allocator, d);
        try merged.append(cloned);
    }

    // Gather plugin-sourced configs. A failure to list plugins degrades to "no
    // overrides" so a broken plugin dir cannot brick LSP startup.
    const plugins = @import("../plugins.zig");
    const specs = plugins.list(allocator, cwd) catch {
        return merged.toOwnedSlice();
    };
    defer plugins.freeList(allocator, specs);

    for (specs) |spec| {
        if (!spec.enabled) continue;
        for (spec.lsp_servers) |*pcfg| {
            const cloned = try cloneConfig(allocator, pcfg);
            try mergeOne(allocator, &merged, cloned);
        }
    }

    return merged.toOwnedSlice();
}

/// Merge one plugin config into the accumulator. For each extension the plugin
/// claims, any default/earlier config that maps that extension loses it (the
/// plugin wins). A default config left with zero extensions after the steal is
/// dropped entirely. The plugin config is then appended.
fn mergeOne(allocator: std.mem.Allocator, merged: *std.array_list.Managed(LspServerConfig), plugin_cfg: LspServerConfig) !void {
    // Steal each of the plugin's extensions from any existing config.
    for (plugin_cfg.extension_to_language) |pel| {
        var i: usize = 0;
        while (i < merged.items.len) {
            const existing = &merged.items[i];
            if (std.mem.eql(u8, existing.name, plugin_cfg.name)) {
                i += 1;
                continue;
            }
            removeExt(allocator, existing, pel.ext);
            if (existing.extension_to_language.len == 0) {
                var dropped = merged.orderedRemove(i);
                dropped.deinit(allocator);
                // Do not advance i; the next element shifted into this slot.
            } else {
                i += 1;
            }
        }
    }

    // If a config with the plugin's name already exists, fold the plugin's
    // extensions in and free the plugin clone; otherwise append the clone.
    for (merged.items) |*existing| {
        if (std.mem.eql(u8, existing.name, plugin_cfg.name)) {
            var pc = plugin_cfg;
            for (pc.extension_to_language) |pel| {
                if (existing.languageForExt(pel.ext) == null) {
                    try appendExtLang(allocator, existing, pel.ext, pel.language);
                }
            }
            pc.deinit(allocator);
            return;
        }
    }
    try merged.append(plugin_cfg);
}

/// Remove the row for `ext` from a config's extension table, if present.
fn removeExt(allocator: std.mem.Allocator, cfg: *LspServerConfig, ext: []const u8) void {
    var idx: ?usize = null;
    for (cfg.extension_to_language, 0..) |el, i| {
        if (std.mem.eql(u8, el.ext, ext)) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;
    allocator.free(cfg.extension_to_language[i].ext);
    allocator.free(cfg.extension_to_language[i].language);
    const last = cfg.extension_to_language.len - 1;
    if (i != last) cfg.extension_to_language[i] = cfg.extension_to_language[last];
    cfg.extension_to_language = allocator.realloc(cfg.extension_to_language, last) catch cfg.extension_to_language[0..last];
}

/// Deep-clone a config into freshly-owned memory.
fn cloneConfig(allocator: std.mem.Allocator, src: *const LspServerConfig) !LspServerConfig {
    const name = try allocator.dupe(u8, src.name);
    errdefer allocator.free(name);
    const command = try allocator.dupe(u8, src.command);
    errdefer allocator.free(command);

    const args = try allocator.alloc([]u8, src.args.len);
    errdefer allocator.free(args);
    var afilled: usize = 0;
    errdefer for (args[0..afilled]) |a| allocator.free(a);
    for (src.args, 0..) |a, i| {
        args[i] = try allocator.dupe(u8, a);
        afilled = i + 1;
    }

    const env = try allocator.alloc(EnvEntry, src.env.len);
    errdefer allocator.free(env);
    var efilled: usize = 0;
    errdefer for (env[0..efilled]) |*e| {
        allocator.free(e.key);
        allocator.free(e.value);
    };
    for (src.env, 0..) |e, i| {
        env[i] = .{ .key = try allocator.dupe(u8, e.key), .value = try allocator.dupe(u8, e.value) };
        efilled = i + 1;
    }

    const ext_lang = try allocator.alloc(ExtLang, src.extension_to_language.len);
    errdefer allocator.free(ext_lang);
    var xfilled: usize = 0;
    errdefer for (ext_lang[0..xfilled]) |*el| {
        allocator.free(el.ext);
        allocator.free(el.language);
    };
    for (src.extension_to_language, 0..) |el, i| {
        ext_lang[i] = .{ .ext = try allocator.dupe(u8, el.ext), .language = try allocator.dupe(u8, el.language) };
        xfilled = i + 1;
    }

    const wf = if (src.workspace_folder) |w| try allocator.dupe(u8, w) else null;
    errdefer if (wf) |w| allocator.free(w);
    const io_opts = if (src.initialization_options_json) |j| try allocator.dupe(u8, j) else null;

    return .{
        .name = name,
        .command = command,
        .args = args,
        .env = env,
        .workspace_folder = wf,
        .extension_to_language = ext_lang,
        .initialization_options_json = io_opts,
        .startup_timeout_ms = src.startup_timeout_ms,
        .max_restarts = src.max_restarts,
    };
}

/// Free a slice of configs and the backing slice.
pub fn freeServers(allocator: std.mem.Allocator, servers: []LspServerConfig) void {
    for (servers) |*s| s.deinit(allocator);
    if (servers.len > 0) allocator.free(servers);
}

fn freeServersList(allocator: std.mem.Allocator, list: *std.array_list.Managed(LspServerConfig)) void {
    for (list.items) |*s| s.deinit(allocator);
    list.deinit();
}

// --- manifest field parse helpers ------------------------------------------

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn jsonI64(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v == .integer) return v.integer;
    return null;
}

fn jsonU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const i = jsonI64(obj, key) orelse return null;
    if (i < 0 or i > std.math.maxInt(u32)) return null;
    return @intCast(i);
}

fn parseArgs(allocator: std.mem.Allocator, value: ?std.json.Value) ![][]u8 {
    // Default args when the manifest omits them: ["--stdio"].
    const v = value orelse return defaultStdioArgs(allocator);
    if (v != .array) return defaultStdioArgs(allocator);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |a| allocator.free(a);
        out.deinit();
    }
    for (v.array.items) |item| {
        if (item != .string) continue;
        try out.append(try allocator.dupe(u8, item.string));
    }
    return out.toOwnedSlice();
}

fn defaultStdioArgs(allocator: std.mem.Allocator) ![][]u8 {
    var args = try allocator.alloc([]u8, 1);
    errdefer allocator.free(args);
    args[0] = try allocator.dupe(u8, "--stdio");
    return args;
}

fn freeArgs(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |a| allocator.free(a);
    if (args.len > 0) allocator.free(args);
}

fn parseEnv(allocator: std.mem.Allocator, value: ?std.json.Value) ![]EnvEntry {
    const v = value orelse return &.{};
    if (v != .object) return &.{};

    var out = std.array_list.Managed(EnvEntry).init(allocator);
    errdefer {
        for (out.items) |*e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        out.deinit();
    }
    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, entry.value_ptr.*.string);
        try out.append(.{ .key = key, .value = val });
    }
    return out.toOwnedSlice();
}

fn freeEnv(allocator: std.mem.Allocator, env: []EnvEntry) void {
    for (env) |*e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    if (env.len > 0) allocator.free(env);
}

fn parseExtensionToLanguage(allocator: std.mem.Allocator, value: ?std.json.Value) ![]ExtLang {
    const v = value orelse return &.{};
    if (v != .object) return &.{};

    var out = std.array_list.Managed(ExtLang).init(allocator);
    errdefer {
        for (out.items) |*el| {
            allocator.free(el.ext);
            allocator.free(el.language);
        }
        out.deinit();
    }
    var it = v.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .string) continue;
        const ext = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(ext);
        const lang = try allocator.dupe(u8, entry.value_ptr.*.string);
        try out.append(.{ .ext = ext, .language = lang });
    }
    return out.toOwnedSlice();
}

fn freeExtLang(allocator: std.mem.Allocator, ext_lang: []ExtLang) void {
    for (ext_lang) |*el| {
        allocator.free(el.ext);
        allocator.free(el.language);
    }
    if (ext_lang.len > 0) allocator.free(ext_lang);
}

/// Re-serialize the opaque `initializationOptions` JSON value back to a string
/// so it can be spliced into the init params. Re-stringifying (rather than
/// keeping the raw bytes) validates the value is well-formed JSON and strips
/// any surrounding whitespace, so the spliced string is always a single valid
/// JSON value. Null when absent.
fn parseInitializationOptions(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]u8 {
    const v = value orelse return null;
    const std_io = @import("../std_io.zig");
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(v, .{}, buf.writer());
    return try buf.toOwnedSlice();
}

// --- Tests ---

const testing = std.testing;

test "defaults yields built-in servers and .zig maps to zls" {
    rt.installForTest();
    const servers = try defaults(testing.allocator);
    defer freeServers(testing.allocator, servers);

    var zls: ?*const LspServerConfig = null;
    var ts: ?*const LspServerConfig = null;
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, "zls")) zls = s;
        if (std.mem.eql(u8, s.name, "typescript-language-server")) ts = s;
    }
    try testing.expect(zls != null);
    try testing.expectEqualStrings("zig", zls.?.languageForExt(".zig").?);
    try testing.expectEqualStrings("zls", zls.?.command);
    try testing.expectEqual(@as(usize, 1), zls.?.args.len);
    try testing.expectEqualStrings("--stdio", zls.?.args[0]);

    // typescript-language-server owns four extensions (grouped under one config).
    try testing.expect(ts != null);
    try testing.expectEqualStrings("typescript", ts.?.languageForExt(".ts").?);
    try testing.expectEqualStrings("javascript", ts.?.languageForExt(".js").?);
    try testing.expectEqualStrings("typescriptreact", ts.?.languageForExt(".tsx").?);
}

test "parseManifestArray parses an lspServers entry with init options + env" {
    rt.installForTest();
    const body =
        \\{"lspServers":[{
        \\  "name":"vue-language-server",
        \\  "command":"vue-language-server",
        \\  "args":["--stdio"],
        \\  "env":{"NODE_ENV":"production"},
        \\  "workspaceFolder":"/proj",
        \\  "extensionToLanguage":{".vue":"vue"},
        \\  "initializationOptions":{"typescript":{"tsdk":"/x"}},
        \\  "startupTimeout":45000,
        \\  "maxRestarts":5
        \\}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();

    const configs = try LspServerConfig.parseManifestArray(testing.allocator, parsed.value.object.get("lspServers"));
    defer freeServers(testing.allocator, configs);

    try testing.expectEqual(@as(usize, 1), configs.len);
    const c = &configs[0];
    try testing.expectEqualStrings("vue-language-server", c.name);
    try testing.expectEqualStrings("vue-language-server", c.command);
    try testing.expectEqualStrings("vue", c.languageForExt(".vue").?);
    try testing.expectEqual(@as(usize, 1), c.env.len);
    try testing.expectEqualStrings("NODE_ENV", c.env[0].key);
    try testing.expectEqualStrings("production", c.env[0].value);
    try testing.expectEqualStrings("/proj", c.workspace_folder.?);
    try testing.expectEqual(@as(i64, 45000), c.startup_timeout_ms);
    try testing.expectEqual(@as(u32, 5), c.max_restarts);
    // initializationOptions is re-serialized to a single valid JSON value.
    try testing.expect(std.mem.indexOf(u8, c.initialization_options_json.?, "\"tsdk\":\"/x\"") != null);
}

test "parseManifestArray defaults command/args/timeout and skips nameless entries" {
    rt.installForTest();
    const body =
        \\{"lspServers":[
        \\  {"extensionToLanguage":{".foo":"foo"}},
        \\  {"name":"barls","extensionToLanguage":{".bar":"bar"}}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();

    const configs = try LspServerConfig.parseManifestArray(testing.allocator, parsed.value.object.get("lspServers"));
    defer freeServers(testing.allocator, configs);

    // The nameless entry is skipped; only "barls" survives.
    try testing.expectEqual(@as(usize, 1), configs.len);
    const c = &configs[0];
    try testing.expectEqualStrings("barls", c.name);
    // command defaults to name, args default to ["--stdio"].
    try testing.expectEqualStrings("barls", c.command);
    try testing.expectEqual(@as(usize, 1), c.args.len);
    try testing.expectEqualStrings("--stdio", c.args[0]);
    try testing.expectEqual(DEFAULT_STARTUP_TIMEOUT_MS, c.startup_timeout_ms);
    try testing.expectEqual(DEFAULT_MAX_RESTARTS, c.max_restarts);
    try testing.expect(c.initialization_options_json == null);
}

test "parseManifestArray on absent/malformed value yields empty" {
    rt.installForTest();
    const empty1 = try LspServerConfig.parseManifestArray(testing.allocator, null);
    defer freeServers(testing.allocator, empty1);
    try testing.expectEqual(@as(usize, 0), empty1.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"lspServers\":\"oops\"}", .{});
    defer parsed.deinit();
    const empty2 = try LspServerConfig.parseManifestArray(testing.allocator, parsed.value.object.get("lspServers"));
    defer freeServers(testing.allocator, empty2);
    try testing.expectEqual(@as(usize, 0), empty2.len);
}

test "mergeOne lets a plugin server override a built-in extension (plugin wins)" {
    rt.installForTest();
    var merged = std.array_list.Managed(LspServerConfig).init(testing.allocator);
    defer freeServersList(testing.allocator, &merged);

    // Seed with the defaults clone (so .zig -> zls is present).
    const base = try defaults(testing.allocator);
    defer freeServers(testing.allocator, base);
    for (base) |*d| try merged.append(try cloneConfig(testing.allocator, d));

    // A plugin server claims .zig with its own binary.
    var ext_lang = try testing.allocator.alloc(ExtLang, 1);
    ext_lang[0] = .{ .ext = try testing.allocator.dupe(u8, ".zig"), .language = try testing.allocator.dupe(u8, "ziglang") };
    var args = try testing.allocator.alloc([]u8, 1);
    args[0] = try testing.allocator.dupe(u8, "--stdio");
    const plugin_cfg = LspServerConfig{
        .name = try testing.allocator.dupe(u8, "custom-zig-ls"),
        .command = try testing.allocator.dupe(u8, "custom-zig-ls"),
        .args = args,
        .env = &.{},
        .workspace_folder = null,
        .extension_to_language = ext_lang,
        .initialization_options_json = null,
        .startup_timeout_ms = DEFAULT_STARTUP_TIMEOUT_MS,
        .max_restarts = DEFAULT_MAX_RESTARTS,
    };
    try mergeOne(testing.allocator, &merged, plugin_cfg);

    // The plugin server now owns .zig; the built-in zls must no longer map it.
    var zls: ?*const LspServerConfig = null;
    var custom: ?*const LspServerConfig = null;
    for (merged.items) |*s| {
        if (std.mem.eql(u8, s.name, "zls")) zls = s;
        if (std.mem.eql(u8, s.name, "custom-zig-ls")) custom = s;
    }
    try testing.expect(custom != null);
    try testing.expectEqualStrings("ziglang", custom.?.languageForExt(".zig").?);
    // zls had only .zig, so after the steal it is dropped entirely.
    try testing.expect(zls == null);
}
