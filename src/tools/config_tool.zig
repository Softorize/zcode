//! Phase 9 Task 8 (tools-07): model-facing ConfigTool.
//!
//! A deferred `Config` tool that lets the model read settings (read-only,
//! auto-allowed) or write them (ask permission on writes), validating against a
//! small allowlist of safe-to-mutate runtime settings.
//!
//! Ported from claude-code-main/src/tools/ConfigTool/ConfigTool.ts: input is
//! `{setting, value?}`; omitting `value` is a read (isReadOnly); a present
//! `value` is a write that must validate against the supported-setting kind
//! (enum option membership, etc.) before applying. We deliberately deviate from
//! the reference's `USER_TYPE==='ant'` gating and expose the tool
//! unconditionally as a deferred tool with a static allowlist. Secrets
//! (api_key, token) are never exposed -- the allowlist is the whole surface.
//!
//! The handler mutates the runtime Config through the same `@constCast`
//! discipline the `/config` REPL path uses (repl_commands.zig). Mutation is kept
//! tiny and explicit: only the keys in `supported` can ever be written, and each
//! write goes through `Config.setOwnedString` / `persistUserConfigField`.

const std = @import("std");
const config_mod = @import("../core/config.zig");
const config_parse = @import("../core/config_parse.zig");
const ui_theme = @import("../core/ui_theme.zig");

/// Kind of a supported setting, used to validate a write before applying it.
pub const Kind = enum {
    /// Free-form string (e.g. model name). Any non-empty value is accepted.
    string,
    /// Theme: validated via ui_theme.parseThemeSetting.
    theme,
    /// Enum: value must be one of `options`.
    enumerated,
};

/// One row of the supported-settings allowlist. `field_name` is the persisted
/// config-file key (config.toml). `options` is only meaningful for `.enumerated`.
pub const Setting = struct {
    /// Model-facing key (also the persisted config-file key).
    key: []const u8,
    kind: Kind,
    options: []const []const u8 = &.{},
};

/// The full set of settings the model may read/write. Intentionally tiny: only
/// safe-to-mutate runtime settings the `/config`, `/model`, and `/permissions`
/// REPL commands already surface. No secrets, no api keys, no tokens.
pub const supported = [_]Setting{
    .{ .key = "theme", .kind = .theme },
    .{ .key = "model", .kind = .string },
    .{ .key = "approval_mode", .kind = .enumerated, .options = &.{ "tiered-auto", "manual", "strict" } },
    .{ .key = "output_style", .kind = .string },
};

/// Look up a supported setting by its model-facing key. Null when unsupported.
pub fn findSetting(key: []const u8) ?Setting {
    for (supported) |s| {
        if (std.mem.eql(u8, s.key, key)) return s;
    }
    return null;
}

/// True when the tool call is a read (no `value` supplied). Mirrors the
/// reference's `isReadOnly` (ConfigTool.ts:90-92): a read is auto-allowed, a
/// write asks. Pure -- the policy classifier and the handler both consult it.
pub fn isReadRequest(value: ?[]const u8) bool {
    return value == null;
}

/// Read the current value of a supported setting out of `cfg`. Returns a slice
/// borrowed from `cfg` (do not free). Null when the key is unsupported.
pub fn readValue(cfg: *const config_mod.Config, key: []const u8) ?[]const u8 {
    if (findSetting(key) == null) return null;
    if (std.mem.eql(u8, key, "theme")) return cfg.ui_theme;
    if (std.mem.eql(u8, key, "model")) return cfg.default_model;
    if (std.mem.eql(u8, key, "approval_mode")) return cfg.approval_mode;
    if (std.mem.eql(u8, key, "output_style")) return cfg.output_style;
    return null;
}

/// Validate a proposed value for a setting WITHOUT mutating anything. Returns an
/// owned error message on failure, or null on success. Pure (allocates only the
/// message), so it is unit-testable. The caller is responsible for the actual
/// mutation only after this returns null.
pub fn validateWrite(allocator: std.mem.Allocator, setting: Setting, value: []const u8) !?[]u8 {
    switch (setting.kind) {
        .string => {
            if (value.len == 0) {
                return try std.fmt.allocPrint(allocator, "error: '{s}' cannot be set to an empty value", .{setting.key});
            }
            return null;
        },
        .theme => {
            if (ui_theme.parseThemeSetting(value) == null) {
                return try std.fmt.allocPrint(
                    allocator,
                    "error: invalid theme '{s}'. Valid: auto, dark, light, dark-daltonized, light-daltonized, dark-ansi, light-ansi",
                    .{value},
                );
            }
            return null;
        },
        .enumerated => {
            for (setting.options) |opt| {
                if (std.ascii.eqlIgnoreCase(opt, value)) return null;
            }
            const joined = try joinOptions(allocator, setting.options);
            defer allocator.free(joined);
            return try std.fmt.allocPrint(
                allocator,
                "error: invalid value '{s}' for '{s}'. Valid: {s}",
                .{ value, setting.key, joined },
            );
        },
    }
}

fn joinOptions(allocator: std.mem.Allocator, options: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (options, 0..) |o, i| {
        total += o.len;
        if (i + 1 < options.len) total += 2; // ", "
    }
    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (options, 0..) |o, i| {
        @memcpy(buf[off .. off + o.len], o);
        off += o.len;
        if (i + 1 < options.len) {
            buf[off] = ',';
            buf[off + 1] = ' ';
            off += 2;
        }
    }
    return buf;
}

/// Apply a validated write to the runtime Config and persist it. Mutates `cfg`
/// in place via setOwnedString (the same path the REPL uses) and best-effort
/// persists to the user config file. Returns the PREVIOUS value (owned) so the
/// handler can report `previous=<old> new=<v>`. The caller MUST have run
/// validateWrite first; this does not re-validate.
pub fn applyWrite(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    setting: Setting,
    value: []const u8,
) ![]u8 {
    // Theme is stored canonicalized (e.g. "dark-daltonized"); normalize the
    // input through the theme formatter so the stored value matches what the
    // REPL `/theme` path writes. validateWrite already guaranteed the theme
    // parses, so the orelse branch is unreachable in practice.
    var stored: []const u8 = value;
    var owned_normalized: ?[]u8 = null;
    defer if (owned_normalized) |n| allocator.free(n);

    if (setting.kind == .theme) {
        if (ui_theme.parseThemeSetting(value)) |parsed| {
            stored = ui_theme.formatThemeSetting(parsed);
        }
    } else if (setting.kind == .enumerated) {
        // approval_mode is stored lowercase (config_parse normalization).
        const lowered = try std.ascii.allocLowerString(allocator, value);
        owned_normalized = lowered;
        stored = lowered;
    }

    const target = settingTarget(cfg, setting.key) orelse return error.UnsupportedSetting;
    const previous = try allocator.dupe(u8, target.*);
    try cfg.setOwnedString(allocator, target, stored);

    config_parse.persistUserConfigField(allocator, setting.key, stored) catch |err| {
        // Non-fatal: the in-memory mutation already took effect, matching the
        // REPL path which also degrades gracefully when persistence fails.
        std.log.warn("config tool: failed to persist '{s}': {s}", .{ setting.key, @errorName(err) });
    };

    return previous;
}

/// Resolve the mutable string field in `cfg` backing a supported key.
fn settingTarget(cfg: *config_mod.Config, key: []const u8) ?*[]u8 {
    if (std.mem.eql(u8, key, "theme")) return &cfg.ui_theme;
    if (std.mem.eql(u8, key, "model")) return &cfg.default_model;
    if (std.mem.eql(u8, key, "approval_mode")) return &cfg.approval_mode;
    if (std.mem.eql(u8, key, "output_style")) return &cfg.output_style;
    return null;
}

/// Entry point used by the dispatch handler. `cfg` is the runtime config; when
/// null (no config plumbing at the call site) the handler returns an error blob
/// rather than crashing. `setting` and `value` come from the tool args (value
/// null = read). Returns an owned result string the model reads.
pub fn run(
    allocator: std.mem.Allocator,
    cfg: ?*config_mod.Config,
    setting_key: []const u8,
    value: ?[]const u8,
) ![]u8 {
    if (setting_key.len == 0) {
        return std.fmt.allocPrint(allocator, "error: missing required field 'setting'", .{});
    }

    const setting = findSetting(setting_key) orelse {
        var keys: [supported.len][]const u8 = undefined;
        for (supported, 0..) |s, i| keys[i] = s.key;
        const joined = try joinOptions(allocator, &keys);
        defer allocator.free(joined);
        return std.fmt.allocPrint(
            allocator,
            "error: unsupported setting '{s}'. Supported: {s}",
            .{ setting_key, joined },
        );
    };

    const c = cfg orelse {
        return std.fmt.allocPrint(allocator, "error: config not available in this context", .{});
    };

    // Read path: value omitted.
    if (isReadRequest(value)) {
        const current = readValue(c, setting_key) orelse "";
        return std.fmt.allocPrint(allocator, "setting={s} value={s}", .{ setting_key, current });
    }

    // Write path: validate then apply.
    const v = value.?;
    if (try validateWrite(allocator, setting, v)) |err_msg| {
        // validateWrite owns err_msg; return it directly (the model reads it).
        return err_msg;
    }

    const previous = try applyWrite(allocator, c, setting, v);
    defer allocator.free(previous);

    const new_value = readValue(c, setting_key) orelse v;
    return std.fmt.allocPrint(
        allocator,
        "setting={s} previous={s} new={s}",
        .{ setting_key, previous, new_value },
    );
}

// --- Tests ---

const testing = std.testing;
const rt = @import("zcode_runtime");

test "config read returns current value and is read-only" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // Read request: value omitted.
    try testing.expect(isReadRequest(null));
    try testing.expect(!isReadRequest("dark"));

    const out = try run(testing.allocator, &cfg, "theme", null);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("setting=theme value=dark", out);
}

test "config write to enum with invalid option errors and does not mutate" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const before = try testing.allocator.dupe(u8, cfg.approval_mode);
    defer testing.allocator.free(before);

    const out = try run(testing.allocator, &cfg, "approval_mode", "bogus-mode");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "error: invalid value"));
    // Config unchanged.
    try testing.expectEqualStrings(before, cfg.approval_mode);
}

test "config write to invalid theme errors and does not mutate" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, &cfg, "theme", "neon-pink");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "error: invalid theme"));
    try testing.expectEqualStrings("dark", cfg.ui_theme);
}

test "config valid write updates in-memory config and reports previous+new" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, &cfg, "theme", "light");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("setting=theme previous=dark new=light", out);
    try testing.expectEqualStrings("light", cfg.ui_theme);
}

test "config valid enum write lowercases and reports previous+new" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, &cfg, "approval_mode", "Manual");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("setting=approval_mode previous=tiered-auto new=manual", out);
    try testing.expectEqualStrings("manual", cfg.approval_mode);
}

test "config unsupported setting is rejected and never exposes secrets" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    // provider_api_key is a secret; it must not be a supported key.
    try testing.expect(findSetting("provider_api_key") == null);

    const out = try run(testing.allocator, &cfg, "provider_api_key", null);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "error: unsupported setting"));
}

test "config model write accepts any non-empty string" {
    rt.installForTest();
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const out = try run(testing.allocator, &cfg, "model", "claude-haiku-4-5");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("setting=model previous=claude-opus-4-6 new=claude-haiku-4-5", out);
    try testing.expectEqualStrings("claude-haiku-4-5", cfg.default_model);

    // Empty value rejected.
    const out2 = try run(testing.allocator, &cfg, "model", "");
    defer testing.allocator.free(out2);
    try testing.expect(std.mem.startsWith(u8, out2, "error: 'model' cannot be set to an empty value"));
}
