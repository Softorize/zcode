//! Per-project MCP server approval and enable/disable toggles (mcp-06).
//!
//! Project (`.mcp.json`) servers are NOT implicitly trusted: before zcode
//! connects to one it must be `approved`. The status is derived from the
//! enable/disable lists in settings plus the run mode, mirroring the
//! reference `getProjectMcpServerStatus` (`services/mcp/utils.ts:351-406`):
//!
//!   - rejected if the name is in `disabledMcpjsonServers`;
//!   - approved if the name is in `enabledMcpjsonServers`;
//!   - approved if `enableAllProjectMcpServers` is set;
//!   - approved in bypass-permissions mode, but ONLY when project MCP is
//!     enabled AND the bypass signal did NOT come from project settings (a
//!     project cannot self-approve via a bypass flag it ships - the SECURITY
//!     carve-out at `utils.ts:379-385`);
//!   - approved in non-interactive mode, but ONLY when project MCP is enabled;
//!   - otherwise pending.
//!
//! A separate pair of toggles (`isMcpServerDisabled` / `setMcpServerEnabled`,
//! `services/mcp/config.ts:1528-1578`) gates ANY server (not just project
//! scope) via `disabledMcpServers` / `enabledMcpServers`, with a
//! default-disabled builtin requiring an explicit opt-in.
//!
//! This module is intentionally pure: the status/disabled predicates take
//! plain settings structs (no disk access) so they are exhaustively testable
//! under the custom runner. The disk-backed loaders that fill these structs
//! live alongside (`loadProjectApprovalSettings` / `loadToggleSettings`) and
//! reuse `core/settings_sources.zig`, but the parity-critical decision logic
//! is the pure part.
//!
//! NOTE on name normalization: the reference normalizes server names
//! (`normalizeNameForMCP`) before comparison. zcode has no such normalizer
//! yet, so names are compared raw. A `My-Server` vs `my_server` mismatch is a
//! known limitation; document it where it matters rather than silently
//! diverging.

const std = @import("std");
const settings_sources = @import("settings_sources.zig");
const mcp_config = @import("mcp_config.zig");

/// The approval state of a project-scope MCP server. Mirrors the
/// `approved`/`rejected`/`pending` triad in the reference.
pub const ProjectServerStatus = enum {
    approved,
    rejected,
    pending,
};

/// Whether the current zcode run can interactively prompt the operator.
/// Non-interactive (headless / CI / piped) runs auto-approve project MCP
/// servers when project MCP is enabled, matching the reference carve-out.
pub const RunMode = enum {
    interactive,
    non_interactive,
};

/// The inputs `getProjectMcpServerStatus` needs, pre-resolved from settings.
/// Keeping the SOURCE distinction baked in here (rather than passing raw
/// settings) is what makes the bypass security carve-out enforceable: the
/// loader decides whether the bypass signal came from project settings, and
/// the pure decision function trusts that flag.
pub const ProjectApprovalSettings = struct {
    /// `disabledMcpjsonServers`: names explicitly rejected.
    disabled_mcpjson_servers: []const []const u8 = &.{},
    /// `enabledMcpjsonServers`: names explicitly approved.
    enabled_mcpjson_servers: []const []const u8 = &.{},
    /// `enableAllProjectMcpServers`: approve every project server.
    enable_all_project_mcp_servers: bool = false,
    /// Whether project MCP is enabled at all (the "projectSettings enabled"
    /// gate the reference checks before honoring bypass/non-interactive
    /// auto-approval). When false, neither bypass nor non-interactive mode
    /// auto-approves a project server.
    project_mcp_enabled: bool = true,
    /// Whether bypass-permissions mode is active AND its signal came from a
    /// NON-project source (user / local / flag / policy). A bypass flag that
    /// originated in project settings must NOT auto-approve project servers
    /// (`utils.ts:379-385`); the loader sets this to false in that case.
    bypass_from_non_project: bool = false,
};

/// Compute the approval status of a project-scope MCP server named `name`.
/// Pure: all inputs are explicit. Precedence matches the reference exactly.
pub fn getProjectMcpServerStatus(
    name: []const u8,
    settings: *const ProjectApprovalSettings,
    mode: RunMode,
) ProjectServerStatus {
    // 1. Explicit disable wins over everything.
    if (containsName(settings.disabled_mcpjson_servers, name)) return .rejected;

    // 2. Explicit enable, or enable-all.
    if (containsName(settings.enabled_mcpjson_servers, name)) return .approved;
    if (settings.enable_all_project_mcp_servers) return .approved;

    // 3. Bypass-permissions auto-approve: only when project MCP is enabled and
    //    the bypass did NOT come from project settings (security carve-out).
    if (settings.project_mcp_enabled and settings.bypass_from_non_project) return .approved;

    // 4. Non-interactive auto-approve: only when project MCP is enabled.
    if (settings.project_mcp_enabled and mode == .non_interactive) return .approved;

    // 5. Default: pending (awaits interactive approval).
    return .pending;
}

/// The inputs `isMcpServerDisabled` / `setMcpServerEnabled` operate on. The
/// two name lists are the `disabledMcpServers` / `enabledMcpServers` settings
/// (any scope, any transport). `default_disabled` is the builtin-server
/// default-off flag: such a server is disabled UNLESS it appears in the
/// enabled list (explicit opt-in), per `config.ts:1528-1578`.
pub const ToggleSettings = struct {
    disabled_mcp_servers: []const []const u8 = &.{},
    enabled_mcp_servers: []const []const u8 = &.{},
};

/// Whether a server named `name` is disabled. A server in `disabledMcpServers`
/// is disabled; a `default_disabled` (builtin-off) server is disabled unless it
/// is in `enabledMcpServers` (explicit opt-in); otherwise enabled.
pub fn isMcpServerDisabled(
    name: []const u8,
    settings: *const ToggleSettings,
    default_disabled: bool,
) bool {
    if (containsName(settings.disabled_mcp_servers, name)) return true;
    if (default_disabled and !containsName(settings.enabled_mcp_servers, name)) return true;
    return false;
}

/// Result of mutating a `ToggleSettings` in place. The two lists are owned by
/// the caller; `setMcpServerEnabled` allocates fresh lists and the caller must
/// free the old ones (or call `deinit` on this result when it owns them).
pub const ToggleUpdate = struct {
    disabled_mcp_servers: [][]u8,
    enabled_mcp_servers: [][]u8,

    pub fn deinit(self: *ToggleUpdate, allocator: std.mem.Allocator) void {
        freeNameList(allocator, self.disabled_mcp_servers);
        freeNameList(allocator, self.enabled_mcp_servers);
        self.* = undefined;
    }
};

/// Produce updated `disabledMcpServers` / `enabledMcpServers` lists that set
/// `name`'s enabled state to `enabled`. Mirrors `setMcpServerEnabled`
/// (`config.ts:1528-1578`):
///   - enabling   => add to `enabledMcpServers`, remove from `disabledMcpServers`;
///   - disabling  => add to `disabledMcpServers`, remove from `enabledMcpServers`.
/// The returned lists are freshly allocated (the input is not mutated). Caller
/// owns and frees the result via `ToggleUpdate.deinit`.
pub fn setMcpServerEnabled(
    allocator: std.mem.Allocator,
    settings: *const ToggleSettings,
    name: []const u8,
    enabled: bool,
) !ToggleUpdate {
    if (enabled) {
        const new_enabled = try withName(allocator, settings.enabled_mcp_servers, name);
        errdefer freeNameList(allocator, new_enabled);
        const new_disabled = try withoutName(allocator, settings.disabled_mcp_servers, name);
        return .{ .disabled_mcp_servers = new_disabled, .enabled_mcp_servers = new_enabled };
    } else {
        const new_disabled = try withName(allocator, settings.disabled_mcp_servers, name);
        errdefer freeNameList(allocator, new_disabled);
        const new_enabled = try withoutName(allocator, settings.enabled_mcp_servers, name);
        return .{ .disabled_mcp_servers = new_disabled, .enabled_mcp_servers = new_enabled };
    }
}

// ── List helpers ────────────────────────────────────────────────────────

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn freeNameList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |n| allocator.free(n);
    if (list.len > 0) allocator.free(list);
}

/// Return a freshly-allocated copy of `list` with `name` appended if not
/// already present.
fn withName(allocator: std.mem.Allocator, list: []const []const u8, name: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit();
    }
    var present = false;
    for (list) |n| {
        try out.append(try allocator.dupe(u8, n));
        if (std.mem.eql(u8, n, name)) present = true;
    }
    if (!present) try out.append(try allocator.dupe(u8, name));
    return out.toOwnedSlice();
}

/// Return a freshly-allocated copy of `list` with every occurrence of `name`
/// removed.
fn withoutName(allocator: std.mem.Allocator, list: []const []const u8, name: []const u8) ![][]u8 {
    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit();
    }
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) continue;
        try out.append(try allocator.dupe(u8, n));
    }
    return out.toOwnedSlice();
}

// ── Merge integration ───────────────────────────────────────────────────

/// Filter a merged server list in place: drop every PROJECT-scope server whose
/// approval status is not `approved`, and drop ANY server (regardless of
/// scope) that `isMcpServerDisabled` reports disabled. This is the hook
/// `mcp_config.mergeScopes` callers use after the precedence merge so pending
/// project servers and disabled servers never reach the transport layer.
///
/// Ownership mirrors `mcp_policy.filterMcpServersByPolicy`: after the call the
/// caller owns ONLY the new `servers.*` slice; the old backing buffer is freed
/// and dropped configs are deinit'd here. Returns the dropped server names so
/// callers can warn (caller frees the returned slice).
pub const DropResult = struct {
    dropped: [][]u8,

    pub fn deinit(self: *DropResult, allocator: std.mem.Allocator) void {
        freeNameList(allocator, self.dropped);
        self.* = undefined;
    }
};

pub fn filterProjectServers(
    allocator: std.mem.Allocator,
    servers: *[]mcp_config.ServerConfig,
    project_settings: *const ProjectApprovalSettings,
    toggles: *const ToggleSettings,
    mode: RunMode,
) !DropResult {
    var dropped = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (dropped.items) |d| allocator.free(d);
        dropped.deinit();
    }

    var survivors = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer {
        for (survivors.items) |*s| s.deinit(allocator);
        survivors.deinit();
    }

    const slice = servers.*;
    for (slice) |srv| {
        var keep = true;

        // Project-scope servers must be approved.
        if (srv.scope == .project) {
            if (getProjectMcpServerStatus(srv.name, project_settings, mode) != .approved) {
                keep = false;
            }
        }

        // Any disabled server (any scope) is dropped. `default_disabled` is
        // false here: zcode has no builtin default-off MCP servers, so a
        // server is disabled only when explicitly listed.
        if (keep and isMcpServerDisabled(srv.name, toggles, false)) {
            keep = false;
        }

        if (keep) {
            try survivors.append(srv);
        } else {
            try dropped.append(try allocator.dupe(u8, srv.name));
            var d = srv;
            d.deinit(allocator);
        }
    }

    if (slice.len > 0) allocator.free(slice);
    servers.* = try survivors.toOwnedSlice();
    return .{ .dropped = try dropped.toOwnedSlice() };
}

// ── Disk-backed loaders ─────────────────────────────────────────────────

/// Read a string-array settings key, merged across all five disk sources
/// (later sources append - these are collections, not scalar overrides). A key
/// absent from every source yields an empty list. Caller owns the result.
fn loadNameList(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    key: []const u8,
) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (list.items) |n| allocator.free(n);
        list.deinit();
    }
    for (settings_sources.sourceOrder()) |source| {
        var parsed = (settings_sources.readSource(allocator, cwd, source, null) catch null) orelse continue;
        defer parsed.deinit();
        const arr = settings_sources.getArray(parsed.value, key) orelse continue;
        for (arr) |item| {
            switch (item) {
                .string => |s| try list.append(try allocator.dupe(u8, s)),
                else => {},
            }
        }
    }
    return list.toOwnedSlice();
}

/// Resolved, owned approval settings read from disk. Free with `deinit`.
pub const LoadedApproval = struct {
    disabled_mcpjson_servers: [][]u8,
    enabled_mcpjson_servers: [][]u8,
    enable_all_project_mcp_servers: bool,
    project_mcp_enabled: bool,
    bypass_from_non_project: bool,

    pub fn deinit(self: *LoadedApproval, allocator: std.mem.Allocator) void {
        freeNameList(allocator, self.disabled_mcpjson_servers);
        freeNameList(allocator, self.enabled_mcpjson_servers);
        self.* = undefined;
    }

    /// Borrow a pure `ProjectApprovalSettings` view over the loaded lists. The
    /// view is valid as long as the `LoadedApproval` is alive.
    pub fn view(self: *const LoadedApproval) ProjectApprovalSettings {
        return .{
            .disabled_mcpjson_servers = self.disabled_mcpjson_servers,
            .enabled_mcpjson_servers = self.enabled_mcpjson_servers,
            .enable_all_project_mcp_servers = self.enable_all_project_mcp_servers,
            .project_mcp_enabled = self.project_mcp_enabled,
            .bypass_from_non_project = self.bypass_from_non_project,
        };
    }
};

/// Whether bypass-permissions mode is set in any NON-project source (user /
/// local / flag / policy). Project settings are deliberately excluded so a
/// project cannot self-approve its servers via a bypass flag it ships
/// (`utils.ts:379-385`).
fn bypassFromNonProject(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const non_project = [_]settings_sources.Source{ .user, .local, .flag, .policy };
    for (non_project) |source| {
        if (settings_sources.sourceScalarBool(allocator, cwd, null, source, "bypassPermissions")) |b| {
            if (b) return true;
        }
        // The reference also recognizes the permission-mode form.
        if (settings_sources.readSource(allocator, cwd, source, null) catch null) |parsed| {
            var p = parsed;
            defer p.deinit();
            if (settings_sources.getString(p.value, "defaultMode")) |m| {
                if (std.mem.eql(u8, m, "bypassPermissions")) return true;
            }
        }
    }
    return false;
}

/// Load the project-approval settings from disk rooted at `cwd`. Caller owns
/// the result; free with `LoadedApproval.deinit`.
pub fn loadProjectApprovalSettings(allocator: std.mem.Allocator, cwd: []const u8) !LoadedApproval {
    const disabled = try loadNameList(allocator, cwd, "disabledMcpjsonServers");
    errdefer freeNameList(allocator, disabled);
    const enabled = try loadNameList(allocator, cwd, "enabledMcpjsonServers");
    errdefer freeNameList(allocator, enabled);

    const enable_all = settings_sources.mergedScalarBool(allocator, cwd, null, "enableAllProjectMcpServers") orelse false;
    // Project MCP is considered enabled unless settings explicitly disable it.
    const project_enabled = settings_sources.mergedScalarBool(allocator, cwd, null, "enableProjectMcpServers") orelse true;

    return .{
        .disabled_mcpjson_servers = disabled,
        .enabled_mcpjson_servers = enabled,
        .enable_all_project_mcp_servers = enable_all,
        .project_mcp_enabled = project_enabled,
        .bypass_from_non_project = bypassFromNonProject(allocator, cwd),
    };
}

/// Resolved, owned toggle settings read from disk. Free with `deinit`.
pub const LoadedToggles = struct {
    disabled_mcp_servers: [][]u8,
    enabled_mcp_servers: [][]u8,

    pub fn deinit(self: *LoadedToggles, allocator: std.mem.Allocator) void {
        freeNameList(allocator, self.disabled_mcp_servers);
        freeNameList(allocator, self.enabled_mcp_servers);
        self.* = undefined;
    }

    pub fn view(self: *const LoadedToggles) ToggleSettings {
        return .{
            .disabled_mcp_servers = self.disabled_mcp_servers,
            .enabled_mcp_servers = self.enabled_mcp_servers,
        };
    }
};

/// Load the enable/disable toggle settings from disk rooted at `cwd`. Caller
/// owns the result; free with `LoadedToggles.deinit`.
pub fn loadToggleSettings(allocator: std.mem.Allocator, cwd: []const u8) !LoadedToggles {
    const disabled = try loadNameList(allocator, cwd, "disabledMcpServers");
    errdefer freeNameList(allocator, disabled);
    const enabled = try loadNameList(allocator, cwd, "enabledMcpServers");
    return .{ .disabled_mcp_servers = disabled, .enabled_mcp_servers = enabled };
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "getProjectMcpServerStatus: disabled-list => rejected" {
    const settings = ProjectApprovalSettings{
        .disabled_mcpjson_servers = &.{"foo"},
        .enabled_mcpjson_servers = &.{"foo"}, // disabled wins even if also enabled
        .enable_all_project_mcp_servers = true,
    };
    try testing.expectEqual(
        ProjectServerStatus.rejected,
        getProjectMcpServerStatus("foo", &settings, .interactive),
    );
}

test "getProjectMcpServerStatus: enabled-list => approved" {
    const settings = ProjectApprovalSettings{ .enabled_mcpjson_servers = &.{"foo"} };
    try testing.expectEqual(
        ProjectServerStatus.approved,
        getProjectMcpServerStatus("foo", &settings, .interactive),
    );
}

test "getProjectMcpServerStatus: enable-all => approved" {
    const settings = ProjectApprovalSettings{ .enable_all_project_mcp_servers = true };
    try testing.expectEqual(
        ProjectServerStatus.approved,
        getProjectMcpServerStatus("anything", &settings, .interactive),
    );
}

test "getProjectMcpServerStatus: non-interactive + project-enabled => approved" {
    const settings = ProjectApprovalSettings{ .project_mcp_enabled = true };
    try testing.expectEqual(
        ProjectServerStatus.approved,
        getProjectMcpServerStatus("foo", &settings, .non_interactive),
    );
}

test "getProjectMcpServerStatus: non-interactive but project NOT enabled => pending" {
    const settings = ProjectApprovalSettings{ .project_mcp_enabled = false };
    try testing.expectEqual(
        ProjectServerStatus.pending,
        getProjectMcpServerStatus("foo", &settings, .non_interactive),
    );
}

test "getProjectMcpServerStatus: bypass from non-project => approved" {
    const settings = ProjectApprovalSettings{
        .project_mcp_enabled = true,
        .bypass_from_non_project = true,
    };
    try testing.expectEqual(
        ProjectServerStatus.approved,
        getProjectMcpServerStatus("foo", &settings, .interactive),
    );
}

test "getProjectMcpServerStatus: bypass via project settings does NOT approve" {
    // A project ships a bypass flag: the loader sets bypass_from_non_project to
    // false, so the project server stays pending (security carve-out).
    const settings = ProjectApprovalSettings{
        .project_mcp_enabled = true,
        .bypass_from_non_project = false,
    };
    try testing.expectEqual(
        ProjectServerStatus.pending,
        getProjectMcpServerStatus("foo", &settings, .interactive),
    );
}

test "getProjectMcpServerStatus: default => pending" {
    const settings = ProjectApprovalSettings{};
    try testing.expectEqual(
        ProjectServerStatus.pending,
        getProjectMcpServerStatus("foo", &settings, .interactive),
    );
}

test "isMcpServerDisabled: disabled list, default-disabled opt-in" {
    const s1 = ToggleSettings{ .disabled_mcp_servers = &.{"foo"} };
    try testing.expect(isMcpServerDisabled("foo", &s1, false));
    try testing.expect(!isMcpServerDisabled("bar", &s1, false));

    // Default-disabled builtin: disabled unless explicitly enabled.
    const s2 = ToggleSettings{ .enabled_mcp_servers = &.{"opt-in"} };
    try testing.expect(isMcpServerDisabled("builtin", &s2, true));
    try testing.expect(!isMcpServerDisabled("opt-in", &s2, true));
    // Not default-disabled and not in the disabled list => enabled.
    try testing.expect(!isMcpServerDisabled("builtin", &s2, false));
}

test "setMcpServerEnabled then isMcpServerDisabled round-trips" {
    const allocator = testing.allocator;

    // Disable "foo".
    var start = ToggleSettings{};
    var disabled_update = try setMcpServerEnabled(allocator, &start, "foo", false);
    defer disabled_update.deinit(allocator);

    const after_disable = ToggleSettings{
        .disabled_mcp_servers = disabled_update.disabled_mcp_servers,
        .enabled_mcp_servers = disabled_update.enabled_mcp_servers,
    };
    try testing.expect(isMcpServerDisabled("foo", &after_disable, false));

    // Re-enable "foo": it leaves the disabled list and enters the enabled list.
    var enabled_update = try setMcpServerEnabled(allocator, &after_disable, "foo", true);
    defer enabled_update.deinit(allocator);

    const after_enable = ToggleSettings{
        .disabled_mcp_servers = enabled_update.disabled_mcp_servers,
        .enabled_mcp_servers = enabled_update.enabled_mcp_servers,
    };
    try testing.expect(!isMcpServerDisabled("foo", &after_enable, false));
    try testing.expectEqual(@as(usize, 0), after_enable.disabled_mcp_servers.len);
    try testing.expectEqual(@as(usize, 1), after_enable.enabled_mcp_servers.len);
    try testing.expectEqualStrings("foo", after_enable.enabled_mcp_servers[0]);
}

test "setMcpServerEnabled is idempotent (no duplicate entries)" {
    const allocator = testing.allocator;
    const start = ToggleSettings{ .disabled_mcp_servers = &.{"foo"} };
    var update = try setMcpServerEnabled(allocator, &start, "foo", false);
    defer update.deinit(allocator);
    // "foo" was already disabled; it must not be duplicated.
    try testing.expectEqual(@as(usize, 1), update.disabled_mcp_servers.len);
}

fn makeProjectServer(allocator: std.mem.Allocator, name: []const u8, scope: mcp_config.ConfigScope) !mcp_config.ServerConfig {
    var srv = mcp_config.ServerConfig{
        .name = try allocator.dupe(u8, name),
        .scope = scope,
        .type = .stdio,
    };
    errdefer srv.deinit(allocator);
    srv.command = try allocator.dupe(u8, "/bin/echo");
    return srv;
}

test "filterProjectServers: drops pending project server, keeps approved" {
    const allocator = testing.allocator;

    var list = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit();
    }
    try list.append(try makeProjectServer(allocator, "approved-srv", .project));
    try list.append(try makeProjectServer(allocator, "pending-srv", .project));
    // A user-scope server is not subject to project approval.
    try list.append(try makeProjectServer(allocator, "user-srv", .user));
    var servers = try list.toOwnedSlice();
    defer mcp_config.freeServerConfigs(allocator, servers);

    const project_settings = ProjectApprovalSettings{ .enabled_mcpjson_servers = &.{"approved-srv"} };
    const toggles = ToggleSettings{};

    var drop = try filterProjectServers(allocator, &servers, &project_settings, &toggles, .interactive);
    defer drop.deinit(allocator);

    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expect(findByName(servers, "approved-srv") != null);
    try testing.expect(findByName(servers, "user-srv") != null);
    try testing.expect(findByName(servers, "pending-srv") == null);

    try testing.expectEqual(@as(usize, 1), drop.dropped.len);
    try testing.expectEqualStrings("pending-srv", drop.dropped[0]);
}

test "filterProjectServers: drops a disabled server regardless of scope" {
    const allocator = testing.allocator;

    var list = std.array_list.Managed(mcp_config.ServerConfig).init(allocator);
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit();
    }
    try list.append(try makeProjectServer(allocator, "keep", .user));
    try list.append(try makeProjectServer(allocator, "off", .user));
    var servers = try list.toOwnedSlice();
    defer mcp_config.freeServerConfigs(allocator, servers);

    const project_settings = ProjectApprovalSettings{};
    const toggles = ToggleSettings{ .disabled_mcp_servers = &.{"off"} };

    var drop = try filterProjectServers(allocator, &servers, &project_settings, &toggles, .non_interactive);
    defer drop.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), servers.len);
    try testing.expectEqualStrings("keep", servers[0].name);
    try testing.expectEqual(@as(usize, 1), drop.dropped.len);
    try testing.expectEqualStrings("off", drop.dropped[0]);
}

fn findByName(servers: []mcp_config.ServerConfig, name: []const u8) ?*mcp_config.ServerConfig {
    for (servers) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}
