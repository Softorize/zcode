//! Central chokepoint for every outbound network call zcode makes.
//!
//! Today, providers, the MCP client, and the web-fetch tool each do
//! their own URL parse + SSRF check before calling `curl` or
//! `std.http.Client`. A central chokepoint has two benefits:
//!   1. One code path to audit and keep consistent.
//!   2. Enforcement of a managed-config egress allowlist so fleet
//!      admins can restrict zcode to specific provider endpoints
//!      (air-gapped / regulated environments).
//!
//! This module implements the policy decision only; the transport
//! (curl or std.http) stays with each caller. Call-site migration is
//! incremental: sites that want the new check call `checkUrl` before
//! initiating the connection.

const std = @import("std");
const ssrf_guard = @import("ssrf_guard.zig");

pub const Decision = enum {
    allow,
    deny_scheme,
    deny_ssrf,
    deny_allowlist,
    deny_denylist,
};

pub const Policy = struct {
    /// Optional exact-host allowlist. If non-empty, only hosts that
    /// match one of the entries are allowed. Set via managed config
    /// (E18) for fleet-locked egress. An entry can be a bare host
    /// ("api.anthropic.com"), or a wildcard-suffix marker
    /// ("*.anthropic.com" - matches api.anthropic.com and
    /// console.anthropic.com but not anthropic.com itself).
    allowlist: []const []const u8 = &.{},
    /// Comma-separated managed-config allowlist using the same entry
    /// syntax as `allowlist`. This avoids per-call allocations when
    /// fleet policy is carried as a config string.
    allowlist_csv: []const u8 = "",
    /// Optional explicit deny list. Hosts matching any entry are
    /// denied REGARDLESS of the allowlist (deny wins, consistent with
    /// the permission-rule deny-always-wins precedence). Entry syntax
    /// is identical to `allowlist` (bare host or "*.example.com"
    /// wildcard-suffix). Mirrors the reference sandbox config's
    /// network.deniedDomains.
    denylist: []const []const u8 = &.{},
    /// Comma-separated managed-config deny list using the same entry
    /// syntax as `denylist`. Evaluated before the allowlist so a
    /// denied host can never be re-allowed by a broad allowlist.
    denylist_csv: []const u8 = "",
    /// When true, the SSRF block-list is applied (RFC1918, link-local,
    /// loopback, etc.). Defaults to true; disable only for explicit
    /// test harnesses.
    ssrf_blocklist_enabled: bool = true,
    /// Allow plaintext HTTP/WS to private LAN hosts (RFC1918 / IPv6 ULA).
    /// This is intentionally opt-in so cloud provider base URLs still
    /// require HTTPS. Use only for explicitly configured local-provider
    /// endpoints such as Ollama on another machine in the user's LAN.
    allow_private_network_plaintext: bool = false,
};

var runtime_allowlist_csv: []const u8 = "";
var runtime_denylist_csv: []const u8 = "";
var runtime_allow_private_network_plaintext: bool = false;

/// Configure process-wide managed egress policy. The slices must live at
/// least as long as zcode runs; main passes fields owned by the loaded config.
pub fn configureRuntimePolicy(
    allowlist_csv: []const u8,
    denylist_csv: []const u8,
    allow_private_network_plaintext: bool,
) void {
    runtime_allowlist_csv = allowlist_csv;
    runtime_denylist_csv = denylist_csv;
    runtime_allow_private_network_plaintext = allow_private_network_plaintext;
}

pub fn resetRuntimePolicyForTesting() void {
    runtime_allowlist_csv = "";
    runtime_denylist_csv = "";
    runtime_allow_private_network_plaintext = false;
}

pub fn checkUrl(allocator: std.mem.Allocator, url: []const u8, policy: Policy) Decision {
    const allow_private_network_plaintext =
        policy.allow_private_network_plaintext or runtime_allow_private_network_plaintext;
    if (!isHttpsOrAllowedPlaintext(allocator, url, allow_private_network_plaintext)) return .deny_scheme;

    if (policy.ssrf_blocklist_enabled and ssrf_guard.urlIsBlockedWithOptions(allocator, url, .{
        .allow_private_networks = allow_private_network_plaintext,
    })) {
        return .deny_ssrf;
    }

    const have_denylist = policy.denylist.len > 0 or policy.denylist_csv.len > 0 or runtime_denylist_csv.len > 0;
    const have_allowlist = policy.allowlist.len > 0 or policy.allowlist_csv.len > 0 or runtime_allowlist_csv.len > 0;

    if (have_denylist or have_allowlist) {
        const host = ssrf_guard.extractHost(url) orelse {
            // No parseable host. A configured allowlist defaults to
            // deny (existing behavior); a denylist alone cannot match,
            // so fall through to allow when no allowlist is set.
            if (have_allowlist) return .deny_allowlist;
            return .allow;
        };

        // Deny list wins: evaluate it BEFORE the allowlist so a denied
        // host can never be re-allowed by a broad allowlist entry.
        if (policy.denylist.len > 0 and hostMatchesList(host, policy.denylist)) return .deny_denylist;
        if (policy.denylist_csv.len > 0 and hostMatchesCsv(host, policy.denylist_csv)) return .deny_denylist;
        if (runtime_denylist_csv.len > 0 and hostMatchesCsv(host, runtime_denylist_csv)) return .deny_denylist;

        if (policy.allowlist.len > 0 and !hostMatchesList(host, policy.allowlist)) return .deny_allowlist;
        if (policy.allowlist_csv.len > 0 and !hostMatchesCsv(host, policy.allowlist_csv)) return .deny_allowlist;
        if (runtime_allowlist_csv.len > 0 and !hostMatchesCsv(host, runtime_allowlist_csv)) return .deny_allowlist;
    }

    return .allow;
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn isHttpOrWs(url: []const u8) bool {
    return startsWithIgnoreCase(url, "http://") or startsWithIgnoreCase(url, "ws://");
}

fn hostIsLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.Io.net.IpAddress.parse(host, 0)) |addr| {
        switch (addr) {
            .ip4 => |ip4| return ip4.bytes[0] == 127,
            .ip6 => |ip6| return std.mem.eql(u8, &ip6.bytes, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
        }
    } else |_| {}
    return false;
}

fn isHttpsOrAllowedPlaintext(allocator: std.mem.Allocator, url: []const u8, allow_private_network_plaintext: bool) bool {
    // TLS-protected schemes (https / wss) are always allowed by
    // scheme. The SSRF guard further rejects RFC1918 / link-local /
    // cloud-metadata destinations.
    if (startsWithIgnoreCase(url, "https://")) return true;
    if (startsWithIgnoreCase(url, "wss://")) return true;
    if (!isHttpOrWs(url)) return false;

    // Permit plaintext http:// / ws:// only for well-known loopback
    // bindings. Ollama, local dev servers, the zcode daemon, and
    // local stdio-bridged-to-WS MCP servers live here.
    const host = ssrf_guard.extractHost(url) orelse return false;
    if (hostIsLoopback(host)) return true;
    return allow_private_network_plaintext and ssrf_guard.hostnameIsPrivateNetwork(allocator, host);
}

// Returns true when `host` matches any entry in `list`. Used for both
// the allow list (match => allowed) and the deny list (match => denied),
// since both share the bare-host / wildcard-suffix entry syntax.
fn hostMatchesList(host: []const u8, list: []const []const u8) bool {
    const bare = bareHost(host);
    for (list) |entry| {
        if (hostMatchesEntry(bare, std.mem.trim(u8, entry, " \t\r\n"))) return true;
    }
    return false;
}

fn hostMatchesCsv(host: []const u8, list_csv: []const u8) bool {
    const bare = bareHost(host);
    var it = std.mem.splitScalar(u8, list_csv, ',');
    while (it.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, " \t\r\n");
        if (entry.len == 0) continue;
        if (hostMatchesEntry(bare, entry)) return true;
    }
    return false;
}

fn bareHost(host: []const u8) []const u8 {
    // Strip optional port suffix from host.
    const colon = std.mem.lastIndexOfScalar(u8, host, ':');
    const bracket = std.mem.lastIndexOfScalar(u8, host, ']');
    const bare_end = if (colon) |c| blk: {
        if (bracket) |b| {
            // Ambiguous: IPv6 bracketed form with port. Trim nothing
            // (host still embeds the bracketed IPv6 representation).
            if (c < b) break :blk host.len;
            break :blk c;
        }
        break :blk c;
    } else host.len;
    return host[0..bare_end];
}

fn hostMatchesEntry(bare: []const u8, entry: []const u8) bool {
    if (entry.len == 0) return false;
    if (std.mem.startsWith(u8, entry, "*.")) {
        const suffix = entry[1..]; // includes leading '.'
        return std.mem.endsWith(u8, bare, suffix) and bare.len > suffix.len;
    }
    return std.mem.eql(u8, bare, entry);
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "https scheme allowed" {
    const d = checkUrl(testing.allocator, "https://api.example.com/x", .{});
    try testing.expectEqual(Decision.allow, d);
}

test "http non-loopback denied" {
    const d = checkUrl(testing.allocator, "http://example.com/x", .{});
    try testing.expectEqual(Decision.deny_scheme, d);
}

test "loopback http allowed" {
    const d = checkUrl(testing.allocator, "http://127.0.0.1:8080/x", .{});
    try testing.expectEqual(Decision.allow, d);
}

test "loopback-looking hostnames are not treated as loopback" {
    try testing.expectEqual(Decision.deny_scheme, checkUrl(testing.allocator, "http://127.0.0.1.evil.test/x", .{}));
    try testing.expectEqual(Decision.deny_scheme, checkUrl(testing.allocator, "http://localhost.evil.test/x", .{}));
}

test "private lan http denied by default" {
    const d = checkUrl(testing.allocator, "http://192.168.1.124:11434/api/chat", .{});
    try testing.expectEqual(Decision.deny_scheme, d);
}

test "private lan http allowed when explicitly enabled" {
    const d = checkUrl(testing.allocator, "http://192.168.1.124:11434/api/chat", .{ .allow_private_network_plaintext = true });
    try testing.expectEqual(Decision.allow, d);
}

test "metadata http stays denied when private lan is enabled" {
    const d = checkUrl(testing.allocator, "http://169.254.169.254/latest/meta-data/", .{ .allow_private_network_plaintext = true });
    try testing.expectEqual(Decision.deny_scheme, d);
}

test "allowlist exact match" {
    const list = [_][]const u8{"api.anthropic.com"};
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.anthropic.com/v1", .{ .allowlist = &list }));
    try testing.expectEqual(Decision.deny_allowlist, checkUrl(testing.allocator, "https://api.openai.com/v1", .{ .allowlist = &list }));
}

test "allowlist wildcard suffix" {
    const list = [_][]const u8{"*.anthropic.com"};
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.anthropic.com/v1", .{ .allowlist = &list }));
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://console.anthropic.com/v1", .{ .allowlist = &list }));
    // The suffix form should NOT match the bare parent domain.
    try testing.expectEqual(Decision.deny_allowlist, checkUrl(testing.allocator, "https://anthropic.com/v1", .{ .allowlist = &list }));
}

test "allowlist csv trims entries and matches wildcard suffix" {
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.anthropic.com/v1", .{ .allowlist_csv = " api.openai.com, *.anthropic.com " }));
    try testing.expectEqual(Decision.deny_allowlist, checkUrl(testing.allocator, "https://api.groq.com/v1", .{ .allowlist_csv = "api.openai.com,*.anthropic.com" }));
}

test "runtime allowlist is enforced by default policy" {
    configureRuntimePolicy("api.openai.com", "", false);
    defer resetRuntimePolicyForTesting();

    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.openai.com/v1", .{}));
    try testing.expectEqual(Decision.deny_allowlist, checkUrl(testing.allocator, "https://api.anthropic.com/v1", .{}));
}

test "runtime private lan plaintext opt-in" {
    configureRuntimePolicy("", "", true);
    defer resetRuntimePolicyForTesting();

    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "http://192.168.1.124:11434/api/chat", .{}));
}

test "denylist denies even with empty allowlist" {
    const deny = [_][]const u8{"evil.com"};
    try testing.expectEqual(Decision.deny_denylist, checkUrl(testing.allocator, "https://evil.com/x", .{ .denylist = &deny }));
    // A host not on the deny list, with no allowlist set, is allowed.
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://good.com/x", .{ .denylist = &deny }));
}

test "denylist wins over a permissive allowlist" {
    const deny = [_][]const u8{"evil.com"};
    // The allowlist explicitly lists evil.com, but the deny list is
    // evaluated first, so evil.com is denied while good.com is allowed.
    try testing.expectEqual(Decision.deny_denylist, checkUrl(testing.allocator, "https://evil.com/x", .{ .allowlist_csv = "evil.com,good.com", .denylist = &deny }));
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://good.com/x", .{ .allowlist_csv = "evil.com,good.com", .denylist = &deny }));
}

test "denylist wildcard suffix" {
    const deny = [_][]const u8{"*.evil.com"};
    try testing.expectEqual(Decision.deny_denylist, checkUrl(testing.allocator, "https://a.evil.com/x", .{ .denylist = &deny }));
    // The suffix form should NOT match the bare parent domain.
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://evil.com/x", .{ .denylist = &deny }));
}

test "denylist csv trims entries and matches wildcard suffix" {
    try testing.expectEqual(Decision.deny_denylist, checkUrl(testing.allocator, "https://api.evil.com/x", .{ .denylist_csv = " good.com, *.evil.com " }));
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.fine.com/x", .{ .denylist_csv = "good.com,*.evil.com" }));
}

test "runtime denylist is enforced by default policy and wins over allowlist" {
    configureRuntimePolicy("*.anthropic.com,evil.com", "evil.com", false);
    defer resetRuntimePolicyForTesting();

    // Allowed via the runtime allowlist suffix.
    try testing.expectEqual(Decision.allow, checkUrl(testing.allocator, "https://api.anthropic.com/v1", .{}));
    // On the allowlist AND the denylist -> deny wins.
    try testing.expectEqual(Decision.deny_denylist, checkUrl(testing.allocator, "https://evil.com/v1", .{}));
}
