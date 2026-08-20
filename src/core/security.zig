const std = @import("std");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const std_io = @import("std_io.zig");
const display_safe = @import("display_safe.zig");
const paths = @import("paths.zig");
const parse_helpers = @import("parse_helpers.zig");

/// Shared JSON-parse wrapper for security/trust registries. A
/// corrupt registry used to leak `error.SyntaxError (provider=...,
/// model=...)` through the agent-runtime error envelope, or worse:
/// silently return an empty list (trust / hook / marketplace
/// visibility disappears without the user knowing). Emit a targeted
/// stderr line naming the offending file and return a distinct
/// error tag so main.zig's per-command switches can translate it
/// into a clean exit 1.
fn parseRegistryJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    path: []const u8,
    cmd_label: []const u8,
) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.SyntaxError, error.UnexpectedToken, error.InvalidCharacter, error.UnexpectedEndOfInput => {
            std_io.stderrWriter().print(
                "error: {s}: registry file is not valid JSON ({s}): {s}\n  - Fix or delete the file; a new empty registry will be created on the next write.\n",
                .{ cmd_label, @errorName(err), path },
            ) catch {};
            return error.InvalidSecurityRegistry;
        },
        else => return err,
    };
}

pub const HookStatus = struct {
    event: []const u8,
    scope: []const u8,
    path: []u8,
    fingerprint: []u8,
    trusted: bool,

    pub fn deinit(self: *HookStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.fingerprint);
    }
};

const HookTrustEntry = struct {
    path: []u8,
    fingerprint: []u8,

    fn deinit(self: *HookTrustEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.fingerprint);
    }
};

/// Append a {path, fingerprint} trust entry in a leak-safe way.
/// Previous per-site code did `try updated.append(.{ .path = try dupe, .fingerprint = try dupe })`, which leaks the path dupe if the
/// fingerprint dupe OOMs and leaks both if the append itself OOMs.
fn appendHookTrustEntry(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(HookTrustEntry),
    path: []const u8,
    fingerprint: []const u8,
) !void {
    try out.ensureUnusedCapacity(1);
    const dup_path = try allocator.dupe(u8, path);
    errdefer allocator.free(dup_path);
    const dup_fingerprint = try allocator.dupe(u8, fingerprint);
    out.appendAssumeCapacity(.{
        .path = dup_path,
        .fingerprint = dup_fingerprint,
    });
}

const MarketplacePolicy = struct {
    allow_prefixes: [][]u8,
    block_prefixes: [][]u8,

    fn deinit(self: *MarketplacePolicy, allocator: std.mem.Allocator) void {
        for (self.allow_prefixes) |prefix| allocator.free(prefix);
        allocator.free(self.allow_prefixes);
        for (self.block_prefixes) |prefix| allocator.free(prefix);
        allocator.free(self.block_prefixes);
    }
};

const Detection = struct {
    kind: []const u8,
    start: usize,
    end: usize,
};

pub fn renderStatusSummary(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const hook_statuses = try collectHookStatuses(allocator, cwd);
    defer freeHookStatuses(allocator, hook_statuses);

    var trusted_hooks: usize = 0;
    var untrusted_hooks: usize = 0;
    for (hook_statuses) |hook| {
        if (hook.trusted) trusted_hooks += 1 else untrusted_hooks += 1;
    }

    var policy = try loadMarketplacePolicy(allocator);
    defer policy.deinit(allocator);

    return std.fmt.allocPrint(
        allocator,
        "security\thooks_trusted={d}\thooks_untrusted={d}\tmarketplace_allow={d}\tmarketplace_block={d}\n",
        .{ trusted_hooks, untrusted_hooks, policy.allow_prefixes.len, policy.block_prefixes.len },
    );
}

pub fn renderHookTrust(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const statuses = try collectHookStatuses(allocator, cwd);
    defer freeHookStatuses(allocator, statuses);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (statuses.len == 0) {
        try out.writer().writeAll("hook trust: none\n");
        return out.toOwnedSlice();
    }

    try out.writer().writeAll("hook trust:\n");
    for (statuses) |status| {
        // Defense-in-depth: filesystem-derived path on a host with a
        // hostile filename could contain control bytes; sanitize so
        // the TSV row stays single-line. fingerprint is sha256 hex
        // so it's already safe -- still sanitize for symmetry and
        // to defend against future code changes.
        const safe_fp = try display_safe.sanitize(allocator, status.fingerprint);
        defer allocator.free(safe_fp);
        const safe_path = try display_safe.sanitize(allocator, status.path);
        defer allocator.free(safe_path);
        try out.writer().print("- {s} ({s}) trusted={} fingerprint={s} path={s}\n", .{
            status.event,
            status.scope,
            status.trusted,
            safe_fp,
            safe_path,
        });
    }
    return out.toOwnedSlice();
}

pub fn allowHook(allocator: std.mem.Allocator, cwd: []const u8, raw_path: []const u8) ![]u8 {
    const path = try normalizePath(allocator, cwd, raw_path);
    defer allocator.free(path);
    const fingerprint = try fingerprintFile(allocator, path);
    defer allocator.free(fingerprint);

    const store_path = try hookTrustStorePath(allocator);
    defer allocator.free(store_path);
    const existing = try loadHookTrustEntries(allocator, store_path);
    defer freeHookTrustEntries(allocator, existing);

    var updated = std.array_list.Managed(HookTrustEntry).init(allocator);
    defer {
        for (updated.items) |*entry| entry.deinit(allocator);
        updated.deinit();
    }

    var replaced = false;
    for (existing) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            replaced = true;
            try appendHookTrustEntry(allocator, &updated, path, fingerprint);
            continue;
        }
        try appendHookTrustEntry(allocator, &updated, entry.path, entry.fingerprint);
    }

    if (!replaced) {
        try appendHookTrustEntry(allocator, &updated, path, fingerprint);
    }

    try writeHookTrustEntries(allocator, store_path, updated.items);
    return std.fmt.allocPrint(allocator, "trusted hook fingerprint {s} -> {s}", .{ path, fingerprint });
}

pub fn revokeHook(allocator: std.mem.Allocator, cwd: []const u8, raw_path: []const u8) ![]u8 {
    const path = try normalizePath(allocator, cwd, raw_path);
    defer allocator.free(path);

    const store_path = try hookTrustStorePath(allocator);
    defer allocator.free(store_path);
    const existing = try loadHookTrustEntries(allocator, store_path);
    defer freeHookTrustEntries(allocator, existing);

    var updated = std.array_list.Managed(HookTrustEntry).init(allocator);
    defer {
        for (updated.items) |*entry| entry.deinit(allocator);
        updated.deinit();
    }

    var removed = false;
    for (existing) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            removed = true;
            continue;
        }
        try appendHookTrustEntry(allocator, &updated, entry.path, entry.fingerprint);
    }

    if (!removed) return error.HookTrustEntryNotFound;
    try writeHookTrustEntries(allocator, store_path, updated.items);
    return std.fmt.allocPrint(allocator, "revoked hook fingerprint trust: {s}", .{path});
}

pub fn isHookTrusted(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8, scope_name: []const u8) !bool {
    if (std.mem.eql(u8, scope_name, "user")) return true;

    const normalized = try normalizePath(allocator, cwd, path);
    defer allocator.free(normalized);
    const fingerprint = try fingerprintFile(allocator, normalized);
    defer allocator.free(fingerprint);

    const store_path = try hookTrustStorePath(allocator);
    defer allocator.free(store_path);
    const entries = try loadHookTrustEntries(allocator, store_path);
    defer freeHookTrustEntries(allocator, entries);

    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.path, normalized)) continue;
        return std.mem.eql(u8, entry.fingerprint, fingerprint);
    }
    return false;
}

pub fn untrustedHookMessage(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    const normalized = try normalizePath(allocator, cwd, path);
    defer allocator.free(normalized);
    const fingerprint = try fingerprintFile(allocator, normalized);
    defer allocator.free(fingerprint);
    return std.fmt.allocPrint(
        allocator,
        "blocked untrusted hook {s} fingerprint={s}; run `zcode trust hook-allow {s}` to trust this version",
        .{ normalized, fingerprint, normalized },
    );
}

pub fn renderMarketplacePolicy(allocator: std.mem.Allocator) ![]u8 {
    var policy = try loadMarketplacePolicy(allocator);
    defer policy.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try out.writer().writeAll("marketplace policy:\n");
    try out.writer().print("allow_prefixes={d}\n", .{policy.allow_prefixes.len});
    for (policy.allow_prefixes) |prefix| {
        // Escape control bytes so a hand-edited
        // marketplace-policy.json with an embedded newline in a
        // prefix doesn't fake a second list entry.
        const safe = try display_safe.sanitize(allocator, prefix);
        defer allocator.free(safe);
        try out.writer().print("- allow {s}\n", .{safe});
    }
    try out.writer().print("block_prefixes={d}\n", .{policy.block_prefixes.len});
    for (policy.block_prefixes) |prefix| {
        const safe = try display_safe.sanitize(allocator, prefix);
        defer allocator.free(safe);
        try out.writer().print("- block {s}\n", .{safe});
    }
    return out.toOwnedSlice();
}

pub fn allowMarketplacePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return mutateMarketplacePrefixes(allocator, prefix, .allow);
}

pub fn blockMarketplacePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return mutateMarketplacePrefixes(allocator, prefix, .block);
}

pub fn unblockMarketplacePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return mutateMarketplacePrefixes(allocator, prefix, .remove_block);
}

pub fn ensureMarketplaceSourceAllowed(allocator: std.mem.Allocator, url: []const u8) !void {
    // Remote HTTP and local file URLs both go through the policy
    // gate. Previously only HTTP was checked; file:// sources bypassed
    // both the allow-list and the block-list, letting a catalog point
    // to any absolute path on disk. Now the same prefix-matching rules
    // apply uniformly. Raw absolute paths (no scheme) are also
    // constrained so a catalog cannot smuggle one in.
    const is_remote = isRemoteHttpUrl(url);
    const is_file = std.mem.startsWith(u8, url, "file://");
    const is_abs_path = !is_remote and !is_file and std.fs.path.isAbsolute(url);
    if (!is_remote and !is_file and !is_abs_path) return;

    var policy = try loadMarketplacePolicy(allocator);
    defer policy.deinit(allocator);

    for (policy.block_prefixes) |prefix| {
        if (urlPrefixMatches(url, prefix)) return error.MarketplaceSourceDenied;
    }

    // When an allow-list is configured, every source must be covered
    // by it (including file:// and absolute paths).
    if (policy.allow_prefixes.len == 0) {
        // No allow-list configured: permit remote HTTP (historical
        // behaviour) but deny local file sources unless the caller
        // explicitly allow-listed them. This keeps the default safe
        // -- a zero-config install cannot be tricked into reading
        // /etc/passwd via a catalog entry.
        if (is_remote) return;
        return error.MarketplaceSourceDenied;
    }
    for (policy.allow_prefixes) |prefix| {
        if (urlPrefixMatches(url, prefix)) return;
    }
    return error.MarketplaceSourceDenied;
}

/// Prefix match that requires a URL-structure boundary right after the
/// prefix so `https://example.com/safe` does NOT match a request for
/// `https://example.com/safer`. A boundary is end-of-string or one of
/// `/`, `?`, `#`. Equal strings always match.
fn urlPrefixMatches(url: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true;
    if (!std.mem.startsWith(u8, url, prefix)) return false;
    if (url.len == prefix.len) return true;
    const next = url[prefix.len];
    return next == '/' or next == '?' or next == '#';
}

pub fn scanContentSummary(allocator: std.mem.Allocator, label: []const u8, content: []const u8) !?[]u8 {
    const detection = firstDetection(content) orelse return null;
    const excerpt = try detectionExcerpt(allocator, content, detection);
    defer allocator.free(excerpt);
    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "secret scan blocked write to {s}: detected {s} near `{s}`",
        .{ label, detection.kind, excerpt },
    ));
}

pub fn scanStagedDiffSummary(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const argv = [_][]const u8{ "git", "-C", cwd, "diff", "--cached", "--no-color", "--unified=0" };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (!(result.term == .exited and result.term.exited == 0)) return null;
    if (result.stdout.len == 0) return null;

    const detection = firstDetection(result.stdout) orelse return null;
    const excerpt = try detectionExcerpt(allocator, result.stdout, detection);
    defer allocator.free(excerpt);
    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "secret scan blocked git commit: detected {s} in staged changes near `{s}`",
        .{ detection.kind, excerpt },
    ));
}

fn collectHookStatuses(allocator: std.mem.Allocator, cwd: []const u8) ![]HookStatus {
    var out = std.array_list.Managed(HookStatus).init(allocator);
    // PRE-EXISTING BUG: the original `errdefer freeHookStatuses(
    // allocator, out.items)` freed the slice as if it were its own
    // allocation, but out.items is backed by the ArrayList's
    // internal buffer -- `allocator.free(slice)` on it produced an
    // invalid free. Previously unreachable because isHookTrusted
    // never returned a non-None error; the pass-38 catch in
    // loadHookTrustEntries now does, which is what surfaced it.
    errdefer {
        for (out.items) |*status| status.deinit(allocator);
        out.deinit();
    }

    inline for ([_]struct { event: []const u8, file: []const u8 }{
        .{ .event = "pre-tool-use", .file = "pre-tool-use.sh" },
        .{ .event = "post-tool-use", .file = "post-tool-use.sh" },
    }) |spec| {
        const user_path = try userHookPath(allocator, spec.file);
        defer allocator.free(user_path);
        if (fileExists(user_path)) {
            try out.ensureUnusedCapacity(1);
            const dup_path = try allocator.dupe(u8, user_path);
            errdefer allocator.free(dup_path);
            const fp = try fingerprintFile(allocator, user_path);
            out.appendAssumeCapacity(.{
                .event = spec.event,
                .scope = "user",
                .path = dup_path,
                .fingerprint = fp,
                .trusted = true,
            });
        }

        const workspace_path = try workspaceHookPath(allocator, cwd, spec.file);
        defer allocator.free(workspace_path);
        if (fileExists(workspace_path)) {
            try out.ensureUnusedCapacity(1);
            const dup_path = try allocator.dupe(u8, workspace_path);
            errdefer allocator.free(dup_path);
            const fp = try fingerprintFile(allocator, workspace_path);
            errdefer allocator.free(fp);
            const trusted = try isHookTrusted(allocator, cwd, workspace_path, "workspace");
            out.appendAssumeCapacity(.{
                .event = spec.event,
                .scope = "workspace",
                .path = dup_path,
                .fingerprint = fp,
                .trusted = trusted,
            });
        }
    }

    return out.toOwnedSlice();
}

fn freeHookStatuses(allocator: std.mem.Allocator, statuses: []HookStatus) void {
    for (statuses) |*status| status.deinit(allocator);
    allocator.free(statuses);
}

fn mutateMarketplacePrefixes(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    comptime mode: enum { allow, block, remove_block },
) ![]u8 {
    const path = try marketplacePolicyPath(allocator);
    defer allocator.free(path);
    var policy = try loadMarketplacePolicy(allocator);
    defer policy.deinit(allocator);

    var allow = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (allow.items) |entry| allocator.free(entry);
        allow.deinit();
    }
    var block = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (block.items) |entry| allocator.free(entry);
        block.deinit();
    }

    for (policy.allow_prefixes) |entry| {
        if (mode == .allow and std.mem.eql(u8, entry, prefix)) continue;
        try parse_helpers.appendOwnedDupe(&allow, allocator, entry);
    }
    // Track whether remove_block actually matched any entry so the
    // CLI can exit 1 on a no-op "unblock a prefix that was never
    // blocked" call. Matches the exit-code discipline established
    // in passes 8-10 for mcp remove / plugins uninstall / keychain
    // delete / trust revoke.
    var removed_block_match = false;
    for (policy.block_prefixes) |entry| {
        if ((mode == .block or mode == .remove_block) and std.mem.eql(u8, entry, prefix)) {
            if (mode == .remove_block) removed_block_match = true;
            continue;
        }
        try parse_helpers.appendOwnedDupe(&block, allocator, entry);
    }

    if (mode == .allow) try parse_helpers.appendOwnedDupe(&allow, allocator, prefix);
    if (mode == .block) try parse_helpers.appendOwnedDupe(&block, allocator, prefix);
    if (mode == .remove_block and !removed_block_match) return error.MarketplacePrefixNotBlocked;

    try writeMarketplacePolicy(allocator, path, allow.items, block.items);
    return std.fmt.allocPrint(allocator, "{s} marketplace prefix {s}", .{
        switch (mode) {
            .allow => "allowed",
            .block => "blocked",
            .remove_block => "unblocked",
        },
        prefix,
    });
}

fn loadHookTrustEntries(allocator: std.mem.Allocator, path: []const u8) ![]HookTrustEntry {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(HookTrustEntry, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try parseRegistryJson(allocator, bytes, path, "hooks");
    defer parsed.deinit();
    if (parsed.value != .array) return allocator.alloc(HookTrustEntry, 0);

    var out = std.array_list.Managed(HookTrustEntry).init(allocator);
    // Free every already-appended entry's strings on error exit. The
    // earlier `defer out.deinit()` only freed the backing storage.
    errdefer {
        for (out.items) |*e| e.deinit(allocator);
        out.deinit();
    }

    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const path_value = getString(item.object, "path") orelse continue;
        const fingerprint = getString(item.object, "fingerprint") orelse continue;
        try appendHookTrustEntry(allocator, &out, path_value, fingerprint);
    }

    return out.toOwnedSlice();
}

fn writeHookTrustEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const HookTrustEntry) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().writeAll("[\n");
    for (entries, 0..) |entry, idx| {
        if (idx > 0) try out.writer().writeAll(",\n");
        try out.writer().print("  {f}", .{std.json.fmt(.{
            .path = entry.path,
            .fingerprint = entry.fingerprint,
        }, .{})});
    }
    try out.writer().writeAll("\n]\n");

    // Atomic write: a SIGINT in the truncate->writeAll window would
    // leave hook-trust.json at 0 bytes, silently revoking every
    // previously-trusted hook on next start. Same discipline as
    // keychain.zig (pass 64), logger.zig (pass 65), and
    // control_plane.zig (pass 66).
    try writeTrustFileAtomic(allocator, path, out.items());
}

fn freeHookTrustEntries(allocator: std.mem.Allocator, entries: []HookTrustEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn loadMarketplacePolicy(allocator: std.mem.Allocator) !MarketplacePolicy {
    const path = try marketplacePolicyPath(allocator);
    defer allocator.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .allow_prefixes = try allocator.alloc([]u8, 0),
                .block_prefixes = try allocator.alloc([]u8, 0),
            };
        },
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try parseRegistryJson(allocator, bytes, path, "trust marketplace");
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{
            .allow_prefixes = try allocator.alloc([]u8, 0),
            .block_prefixes = try allocator.alloc([]u8, 0),
        };
    }

    return .{
        .allow_prefixes = try loadStringArray(allocator, parsed.value.object.get("allow")),
        .block_prefixes = try loadStringArray(allocator, parsed.value.object.get("block")),
    };
}

fn writeMarketplacePolicy(allocator: std.mem.Allocator, path: []const u8, allow: []const []u8, block: []const []u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}\n", .{std.json.fmt(.{
        .allow = allow,
        .block = block,
    }, .{})});

    // Atomic write: same vector as writeHookTrustEntries -- a
    // truncate->SIGINT window would discard every allow/block prefix
    // the user has accumulated and replace it with 0 bytes.
    try writeTrustFileAtomic(allocator, path, out.items());
}

fn writeTrustFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    var nonce: [8]u8 = undefined;
    rng.bytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("security: chmod failed for trust tmp file: {s}", .{@errorName(err)});
        };
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn loadStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) ![][]u8 {
    const arr = value orelse return allocator.alloc([]u8, 0);
    if (arr != .array) return allocator.alloc([]u8, 0);

    var out = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        // Free any strings already duped if a later dupe OOMs, otherwise
        // they leak. The previous `defer out.deinit()` freed only the
        // backing array.
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (arr.array.items) |item| {
        if (item != .string) continue;
        try parse_helpers.appendOwnedDupe(&out, allocator, item.string);
    }
    return out.toOwnedSlice();
}

fn hookTrustStorePath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "trust", "hooks.json" });
}

fn marketplacePolicyPath(allocator: std.mem.Allocator) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "trust", "marketplace-policy.json" });
}

fn userHookPath(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var resolved = try paths.resolve(allocator);
    defer resolved.deinit(allocator);
    return std.fs.path.join(allocator, &.{ resolved.zcode_home, "hooks", filename });
}

fn workspaceHookPath(allocator: std.mem.Allocator, cwd: []const u8, filename: []const u8) ![]u8 {
    const rel = try std.fmt.allocPrint(allocator, "hooks/{s}", .{filename});
    defer allocator.free(rel);
    return paths.workspacePathAlloc(allocator, cwd, rel);
}

fn fingerprintFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (digest) |byte| {
        try out.writer().print("{x:0>2}", .{byte});
    }
    return out.toOwnedSlice();
}

fn normalizePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path) catch allocator.dupe(u8, path);
    }
    const joined = try std.fs.path.join(allocator, &.{ cwd, path });
    defer allocator.free(joined);
    return allocator.dupe(u8, joined) catch allocator.dupe(u8, joined);
}

fn firstDetection(input: []const u8) ?Detection {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const rest = input[i..];
        // OpenAI-style tokens.
        if (std.mem.startsWith(u8, rest, "sk-")) {
            return .{ .kind = "OpenAI-style token", .start = i, .end = consumeSecret(input, i) };
        }
        // GitHub tokens.
        if (std.mem.startsWith(u8, rest, "ghp_") or std.mem.startsWith(u8, rest, "ghu_")) {
            return .{ .kind = "GitHub token", .start = i, .end = consumeSecret(input, i) };
        }
        // Google API keys.
        if (std.mem.startsWith(u8, rest, "AIza")) {
            return .{ .kind = "Google API token", .start = i, .end = consumeSecret(input, i) };
        }
        // AWS access keys.
        if (std.mem.startsWith(u8, rest, "AKIA")) {
            return .{ .kind = "AWS access key", .start = i, .end = consumeSecret(input, i) };
        }
        // Stripe keys.
        if (std.mem.startsWith(u8, rest, "sk_live_") or std.mem.startsWith(u8, rest, "sk_test_") or
            std.mem.startsWith(u8, rest, "rk_live_") or std.mem.startsWith(u8, rest, "rk_test_") or
            std.mem.startsWith(u8, rest, "pk_live_") or std.mem.startsWith(u8, rest, "pk_test_"))
        {
            return .{ .kind = "Stripe key", .start = i, .end = consumeSecret(input, i) };
        }
        // SendGrid keys.
        if (std.mem.startsWith(u8, rest, "SG.")) {
            return .{ .kind = "SendGrid key", .start = i, .end = consumeSecret(input, i) };
        }
        // GitLab tokens.
        if (std.mem.startsWith(u8, rest, "glpat-") or std.mem.startsWith(u8, rest, "glu_")) {
            return .{ .kind = "GitLab token", .start = i, .end = consumeSecret(input, i) };
        }
        // Slack tokens.
        if (std.mem.startsWith(u8, rest, "xoxb-") or std.mem.startsWith(u8, rest, "xoxp-") or std.mem.startsWith(u8, rest, "xoxs-")) {
            return .{ .kind = "Slack token", .start = i, .end = consumeSecret(input, i) };
        }
        // npm tokens.
        if (std.mem.startsWith(u8, rest, "npm_")) {
            return .{ .kind = "npm token", .start = i, .end = consumeSecret(input, i) };
        }
        // PyPI tokens.
        if (std.mem.startsWith(u8, rest, "pypi-")) {
            return .{ .kind = "PyPI token", .start = i, .end = consumeSecret(input, i) };
        }
        // JWT tokens (base64-encoded JSON header).
        if (std.mem.startsWith(u8, rest, "eyJ")) {
            return .{ .kind = "JWT token", .start = i, .end = consumeJwt(input, i) };
        }
        // Database connection strings.
        if (startsWithConnectionString(rest)) |kind| {
            return .{ .kind = kind, .start = i, .end = consumeUntilWhitespace(input, i) };
        }
        // Slack webhook URLs.
        if (std.mem.startsWith(u8, rest, "hooks.slack.com/services/")) {
            return .{ .kind = "Slack webhook", .start = i, .end = consumeUntilWhitespace(input, i) };
        }
        // High-entropy generic token.
        if (isSecretChar(input[i]) and looksLikeLongSecret(rest)) {
            return .{ .kind = "high-entropy token", .start = i, .end = consumeSecret(input, i) };
        }
    }
    return null;
}

fn startsWithConnectionString(input: []const u8) ?[]const u8 {
    const prefixes = [_]struct { prefix: []const u8, kind: []const u8 }{
        .{ .prefix = "postgres://", .kind = "database connection string" },
        .{ .prefix = "postgresql://", .kind = "database connection string" },
        .{ .prefix = "mysql://", .kind = "database connection string" },
        .{ .prefix = "mongodb://", .kind = "database connection string" },
        .{ .prefix = "mongodb+srv://", .kind = "database connection string" },
        .{ .prefix = "redis://", .kind = "database connection string" },
        .{ .prefix = "rediss://", .kind = "database connection string" },
        .{ .prefix = "amqp://", .kind = "message broker connection string" },
        .{ .prefix = "amqps://", .kind = "message broker connection string" },
    };
    for (prefixes) |entry| {
        if (std.mem.startsWith(u8, input, entry.prefix)) return entry.kind;
    }
    return null;
}

fn consumeJwt(input: []const u8, start: usize) usize {
    // JWTs contain alphanumeric chars, dots, underscores, and hyphens.
    var idx = start;
    while (idx < input.len and (isSecretChar(input[idx]) or input[idx] == '=')) : (idx += 1) {}
    return idx;
}

fn consumeUntilWhitespace(input: []const u8, start: usize) usize {
    var idx = start;
    while (idx < input.len and !std.ascii.isWhitespace(input[idx]) and input[idx] != '"' and input[idx] != '\'') : (idx += 1) {}
    return idx;
}

fn detectionExcerpt(allocator: std.mem.Allocator, input: []const u8, detection: Detection) ![]u8 {
    const start = detection.start;
    const end = detection.end;
    const excerpt_start = start -| 6;
    const excerpt_end = @min(input.len, end + 6);
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    for (input[excerpt_start..excerpt_end]) |ch| {
        if (ch == '\n' or ch == '\r' or ch == '\t') {
            try out.append(' ');
        } else {
            try out.append(ch);
        }
    }
    return out.toOwnedSlice();
}

fn consumeSecret(input: []const u8, start: usize) usize {
    var idx = start;
    while (idx < input.len and isSecretChar(input[idx])) : (idx += 1) {}
    return idx;
}

fn looksLikeLongSecret(input: []const u8) bool {
    var len: usize = 0;
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;

    for (input) |ch| {
        if (!isSecretChar(ch)) break;
        len += 1;
        if (std.ascii.isUpper(ch)) has_upper = true;
        if (std.ascii.isLower(ch)) has_lower = true;
        if (std.ascii.isDigit(ch)) has_digit = true;
    }

    return len >= 20 and has_upper and has_lower and has_digit;
}

fn isSecretChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn isRemoteHttpUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

const testing = std.testing;

test "urlPrefixMatches requires URL boundary after prefix" {
    try testing.expect(urlPrefixMatches("https://example.com/safe", "https://example.com/safe"));
    try testing.expect(urlPrefixMatches("https://example.com/safe/path", "https://example.com/safe"));
    try testing.expect(urlPrefixMatches("https://example.com/safe?x=1", "https://example.com/safe"));
    try testing.expect(urlPrefixMatches("https://example.com/safe#frag", "https://example.com/safe"));
    try testing.expect(!urlPrefixMatches("https://example.com/safer", "https://example.com/safe"));
    try testing.expect(!urlPrefixMatches("https://example.com/safe-evil", "https://example.com/safe"));
}

test "scanContentSummary detects likely secrets" {
    const sample = "token=" ++ "gh" ++ "p_" ++ "demoToken" ++ "1234567890";
    const summary = try scanContentSummary(testing.allocator, "demo.txt", sample);
    defer if (summary) |value| testing.allocator.free(value);
    // Assert the specific detection kind, not just that *something* matched.
    // Previously these tests only checked `!= null`, which would silently
    // pass even if every secret pattern returned the same wrong kind.
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "GitHub token") != null);
}

test "scanContentSummary ignores normal text" {
    const summary = try scanContentSummary(testing.allocator, "demo.txt", "hello world");
    try testing.expect(summary == null);
}

test "scanContentSummary detects Stripe keys" {
    const sample = "key=" ++ "sk" ++ "_live_" ++ "abc" ++ "DEF" ++ "123456" ++ "xyz";
    const summary = try scanContentSummary(testing.allocator, "config.txt", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "Stripe key") != null);
}

test "scanContentSummary detects SendGrid keys" {
    const sample = "api=" ++ "SG" ++ "." ++ "abcDEF" ++ "123456" ++ "xyzABC";
    const summary = try scanContentSummary(testing.allocator, "config.txt", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "SendGrid key") != null);
}

test "scanContentSummary detects JWT tokens" {
    const sample = "auth=" ++ "ey" ++ "J" ++ "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature";
    const summary = try scanContentSummary(testing.allocator, "req.txt", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "JWT token") != null);
}

test "scanContentSummary detects database connection strings" {
    const sample = "db=" ++ "post" ++ "gres://" ++ "user:pass@host:5432/db";
    const summary = try scanContentSummary(testing.allocator, "env.txt", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "database connection string") != null);
}

test "scanContentSummary detects npm tokens" {
    const sample = "token=" ++ "np" ++ "m_" ++ "abc" ++ "DEF" ++ "1234567890";
    const summary = try scanContentSummary(testing.allocator, ".npmrc", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "npm token") != null);
}

test "scanContentSummary detects Slack tokens" {
    const sample = "token=" ++ "xo" ++ "xb-" ++ "123" ++ "-456" ++ "-abcDEF";
    const summary = try scanContentSummary(testing.allocator, "config.txt", sample);
    defer if (summary) |v| testing.allocator.free(v);
    try testing.expect(summary != null);
    try testing.expect(std.mem.indexOf(u8, summary.?, "Slack token") != null);
}
