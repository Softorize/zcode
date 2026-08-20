const std = @import("std");
const std_io = @import("std_io.zig");
const config_mod = @import("config.zig");

pub const Gate = struct {
    name: []const u8,
    enabled: bool,
};

const known_gates = [_]Gate{
    .{ .name = "mcp_tool_bridge", .enabled = true },
    .{ .name = "browser_bridge", .enabled = false },
    .{ .name = "preprocessor", .enabled = false },
    .{ .name = "prompt_cache_hints", .enabled = true },
    .{ .name = "instruction_imports", .enabled = true },
    .{ .name = "cloud_telemetry", .enabled = false },
    .{ .name = "control_plane_policy_sync", .enabled = false },
    .{ .name = "control_plane_managed_settings_sync", .enabled = false },
};

pub fn applyKillSwitches(cfg: *config_mod.Config) void {
    if (isKilled(cfg.feature_kill_switches, "mcp_tool_bridge")) cfg.mcp_tool_bridge_enabled = false;
    if (isKilled(cfg.feature_kill_switches, "browser_bridge")) cfg.browser_bridge_enabled = false;
    if (isKilled(cfg.feature_kill_switches, "preprocessor")) cfg.preprocessor_enabled = false;
    if (isKilled(cfg.feature_kill_switches, "prompt_cache_hints")) cfg.prompt_cache_hints_enabled = false;
    if (isKilled(cfg.feature_kill_switches, "instruction_imports")) cfg.instruction_imports_enabled = false;
    if (isKilled(cfg.feature_kill_switches, "cloud_telemetry")) cfg.cloud_telemetry_opt_in = false;
    if (isKilled(cfg.feature_kill_switches, "control_plane_policy_sync")) cfg.control_plane_policy_sync = false;
    if (isKilled(cfg.feature_kill_switches, "control_plane_managed_settings_sync")) cfg.control_plane_managed_settings_sync = false;
}

pub fn renderEffective(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.writeAll("feature gates:\n");
    try writer.print("  kill_switches: {s}\n", .{if (std.mem.trim(u8, cfg.feature_kill_switches, " \t\r\n").len > 0) cfg.feature_kill_switches else "(none)"});
    try writer.writeAll("  precedence: managed config > user/workspace config; kill switches force features off after merge\n\n");

    for (known_gates) |gate| {
        const enabled = effectiveGateEnabled(cfg, gate.name);
        const killed = isKilled(cfg.feature_kill_switches, gate.name);
        try writer.print("  - {s}: {s}", .{ gate.name, if (enabled) "enabled" else "disabled" });
        if (killed) {
            try writer.writeAll(" (forced off by feature_kill_switches)");
        }
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice();
}

pub fn effectiveGateEnabled(cfg: *const config_mod.Config, name: []const u8) bool {
    if (std.mem.eql(u8, name, "mcp_tool_bridge")) return cfg.mcp_tool_bridge_enabled;
    if (std.mem.eql(u8, name, "browser_bridge")) return cfg.browser_bridge_enabled;
    if (std.mem.eql(u8, name, "preprocessor")) return cfg.preprocessor_enabled;
    if (std.mem.eql(u8, name, "prompt_cache_hints")) return cfg.prompt_cache_hints_enabled;
    if (std.mem.eql(u8, name, "instruction_imports")) return cfg.instruction_imports_enabled;
    if (std.mem.eql(u8, name, "cloud_telemetry")) return cfg.cloud_telemetry_opt_in;
    if (std.mem.eql(u8, name, "control_plane_policy_sync")) return cfg.control_plane_policy_sync;
    if (std.mem.eql(u8, name, "control_plane_managed_settings_sync")) return cfg.control_plane_managed_settings_sync;
    return false;
}

pub fn isKilled(raw_list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, raw_list, ", \t\r\n");
    while (it.next()) |raw| {
        if (std.ascii.eqlIgnoreCase(raw, name)) return true;
    }
    return false;
}

const testing = std.testing;

test "isKilled parses comma and whitespace separated gates" {
    try testing.expect(isKilled("browser_bridge, preprocessor prompt_cache_hints", "browser_bridge"));
    try testing.expect(isKilled("browser_bridge, preprocessor prompt_cache_hints", "preprocessor"));
    try testing.expect(isKilled("browser_bridge, preprocessor prompt_cache_hints", "prompt_cache_hints"));
    try testing.expect(!isKilled("browser_bridge,preprocessor", "mcp_tool_bridge"));
}

test "applyKillSwitches forces configured gates off" {
    var cfg = try config_mod.Config.init(testing.allocator);
    defer cfg.deinit(testing.allocator);
    try cfg.setOwnedString(testing.allocator, &cfg.feature_kill_switches, "mcp_tool_bridge,cloud_telemetry");
    cfg.cloud_telemetry_opt_in = true;
    cfg.mcp_tool_bridge_enabled = true;

    applyKillSwitches(&cfg);

    try testing.expect(!cfg.cloud_telemetry_opt_in);
    try testing.expect(!cfg.mcp_tool_bridge_enabled);
}
