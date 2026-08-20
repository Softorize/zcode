const std = @import("std");
const rt = @import("zcode_runtime");
const build_options = @import("build_options");
const parse_helpers = @import("core/parse_helpers.zig");
const egress = @import("core/egress.zig");
const config_mod = @import("core/config.zig");

const default_update_manifest_url = "https://github.com/Softorize/zcode/releases/latest/download/update.json";
const default_release_api_url = "https://api.github.com/repos/Softorize/zcode/releases/latest";

// Cosign / Sigstore identity the updater expects to see stamped into the
// Fulcio certificate for every release artifact signature. Anchored to
// the exact repository and workflow so a stolen Fulcio token from any
// other GitHub project cannot be used to forge a zcode release.
const cosign_identity_regexp = "^https://github.com/Softorize/zcode/\\.github/workflows/release\\.yml@refs/tags/v.*$";
const cosign_oidc_issuer = "https://token.actions.githubusercontent.com";

const ReleaseSource = enum {
    manifest,
    github_api,
};

const ReleaseInfo = struct {
    version: []u8,
    asset_url: []u8,
    checksum: ?[]u8 = null,
    checksum_manifest_url: ?[]u8 = null,
    source: ReleaseSource,

    fn deinit(self: *ReleaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.asset_url);
        if (self.checksum) |value| allocator.free(value);
        if (self.checksum_manifest_url) |value| allocator.free(value);
    }
};

pub fn cmdUpdate(allocator: std.mem.Allocator, writer: anytype) !void {
    return cmdUpdateWithConfig(allocator, null, writer);
}

pub fn cmdUpdateWithConfig(allocator: std.mem.Allocator, cfg_opt: ?*const config_mod.Config, writer: anytype) !void {
    const current_version = build_options.app_version;
    try writer.print("Current version: {s}\n", .{current_version});
    try writer.writeAll("Checking for updates...\n");
    const allow_unsigned_update = envFlag("ZCODE_ALLOW_UNSIGNED_UPDATE");
    // When set, require cosign signature verification to succeed before
    // overwriting the binary. Default is advisory (warn if verification
    // fails but don't block) to ease rollout; enterprise deployments can
    // flip this via managed config or env var.
    const require_signature = requireSignaturePolicy(cfg_opt);
    const pinned_version = pinnedUpdateVersion(cfg_opt);

    const os_tag = @import("builtin").os.tag;
    if (comptime os_tag != .macos and os_tag != .linux) {
        try writer.writeAll("Self-update is supported on macOS and Linux only.\n");
        return;
    }

    const os_str = comptime switch (@import("builtin").os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => "unknown",
    };
    const arch_str = comptime switch (@import("builtin").cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unknown",
    };
    const asset_name = comptime "zcode-" ++ os_str ++ "-" ++ arch_str;

    var release_info = fetchPreferredReleaseInfo(allocator, asset_name) catch {
        try writer.writeAll("Failed to check for updates. Ensure curl is available and you have internet access.\n");
        return;
    };
    defer release_info.deinit(allocator);

    const base_end = std.mem.indexOfScalar(u8, current_version, '+') orelse current_version.len;
    const current_base = current_version[0..base_end];
    const remote_version = release_info.version;

    switch (compareVersions(current_base, remote_version)) {
        .eq => {
            try writer.print("Already up to date (v{s}).\n", .{current_base});
            return;
        },
        .gt => {
            try writer.print(
                "Current build v{s} is newer than the latest release v{s}.\n",
                .{ current_base, remote_version },
            );
            return;
        },
        .lt => {},
    }

    // Enterprise update pin: operator holds a specific version, updater
    // refuses to advance even if a newer release is available. Set via
    // ZCODE_UPDATE_PINNED_VERSION; a matching pin ("stay on X.Y.Z") is a
    // no-op since the version-compare above would have returned .eq.
    if (pinned_version) |pinned| {
        if (compareVersions(remote_version, pinned) == .gt) {
            try writer.print(
                "Update blocked: update_pinned_version={s} (remote v{s}).\n",
                .{ pinned, remote_version },
            );
            return;
        }
    }

    try writer.print("New version available: v{s} (current: v{s})\n", .{ remote_version, current_base });
    try writer.print("Release source: {s}\n", .{switch (release_info.source) {
        .manifest => "manifest",
        .github_api => "github-api",
    }});

    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path_len = std.process.executablePath(rt.io, &exe_path_buf) catch {
        try writer.writeAll("Could not determine current executable path.\n");
        return;
    };
    const exe_path = exe_path_buf[0..exe_path_len];

    const update_path = try std.fmt.allocPrint(allocator, "{s}.update", .{exe_path});
    defer allocator.free(update_path);

    // Reject an asset URL that isn't HTTPS before invoking curl. A
    // compromised manifest or GitHub API response cannot redirect the
    // download to an insecure scheme, and `--proto =https` /
    // `--proto-redir =https` below enforce the same rule on the wire.
    if (!isHttpsUrl(release_info.asset_url)) {
        try writer.print("Refusing to download over insecure scheme: {s}\n", .{release_info.asset_url});
        return;
    }
    // Defense-in-depth: also gate via the central egress chokepoint
    // so SSRF targets (cloud metadata, RFC1918, link-local) cannot
    // be reached even when isHttpsUrl says yes. A compromised manifest
    // pointing at https://169.254.169.254/... would otherwise pass
    // the scheme check and trigger an IMDS fetch.
    switch (egress.checkUrl(allocator, release_info.asset_url, .{})) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => {
            try writer.print("Refusing to download URL refused by egress policy: {s}\n", .{release_info.asset_url});
            return;
        },
    }

    try writer.print("Downloading {s}...\n", .{asset_name});

    // --max-time / --connect-timeout bound the curl. Without them, a
    // dead or slow-loris asset host hangs the auto-updater forever
    // (the user has to Ctrl+C; the binary is never updated and the
    // tmp file leaks). 180s total + 10s connect leaves headroom for
    // a multi-MB binary on a slow link without inviting indefinite
    // waits.
    const dl_args = [_][]const u8{
        "curl",                 "-fsSL",
        "--proto",              "=https",
        "--proto-redir",        "=https",
        "--connect-timeout",    "10",
        "--max-time",           "180",
        "-o",                   update_path,
        release_info.asset_url,
    };
    const dl_result = std.process.run(allocator, rt.io, .{
        .argv = &dl_args,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch {
        try writer.writeAll("Download failed.\n");
        return;
    };
    defer allocator.free(dl_result.stderr);
    defer allocator.free(dl_result.stdout);

    switch (dl_result.term) {
        .exited => |code| {
            if (code != 0) {
                std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
                try writer.writeAll("Download failed.\n");
                return;
            }
        },
        else => {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.writeAll("Download failed.\n");
            return;
        },
    }

    if (release_info.checksum) |expected| {
        const actual = sha256FileHex(allocator, update_path) catch |err| {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.print("Checksum verification failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(actual);

        if (!std.ascii.eqlIgnoreCase(actual, expected)) {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.print(
                "Checksum mismatch for {s}. Expected {s}, got {s}. Update aborted.\n",
                .{ asset_name, expected, actual },
            );
            return;
        }
        try writer.writeAll("Checksum verified.\n");
    } else if (release_info.checksum_manifest_url) |manifest_url| {
        const manifest = fetchUrlViaCurl(allocator, manifest_url, 512 * 1024) catch {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.writeAll("Failed to fetch release checksum manifest.\n");
            return;
        };
        defer allocator.free(manifest);

        const expected_sha = extractChecksumForAsset(allocator, manifest, asset_name) catch |err| {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.print("Checksum parsing failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer if (expected_sha) |value| allocator.free(value);

        if (expected_sha) |expected| {
            const actual = sha256FileHex(allocator, update_path) catch |err| {
                std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
                try writer.print("Checksum verification failed: {s}\n", .{@errorName(err)});
                return;
            };
            defer allocator.free(actual);

            if (!std.ascii.eqlIgnoreCase(actual, expected)) {
                std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
                try writer.print(
                    "Checksum mismatch for {s}. Expected {s}, got {s}. Update aborted.\n",
                    .{ asset_name, expected, actual },
                );
                return;
            }
            try writer.writeAll("Checksum verified.\n");
        } else if (!allow_unsigned_update) {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.print(
                "Checksum entry for {s} not found in manifest. Update aborted.\nSet ZCODE_ALLOW_UNSIGNED_UPDATE=1 to bypass.\n",
                .{asset_name},
            );
            return;
        } else {
            try writer.writeAll("Warning: checksum entry missing, proceeding due to ZCODE_ALLOW_UNSIGNED_UPDATE=1.\n");
        }
    } else if (!allow_unsigned_update) {
        std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
        try writer.writeAll(
            "Release checksum manifest is missing. Update aborted.\nSet ZCODE_ALLOW_UNSIGNED_UPDATE=1 to bypass.\n",
        );
        return;
    } else {
        try writer.writeAll("Warning: no checksum manifest found, proceeding due to ZCODE_ALLOW_UNSIGNED_UPDATE=1.\n");
    }

    // Cosign signature verification on top of the checksum.
    // Even if the checksum manifest is tampered with alongside the
    // binary, the Fulcio certificate binds the signature to zcode's
    // release workflow on GitHub (see cosign_identity_regexp), so a
    // forged manifest cannot forge a matching cosign signature without
    // also compromising the Softorize/zcode GitHub Actions identity.
    const sig_result = verifyCosignSignature(allocator, writer, release_info.asset_url, update_path) catch SignatureResult.missing;
    switch (sig_result) {
        .verified => {},
        .mismatch => {
            std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
            try writer.writeAll("Signature verification FAILED. Update aborted.\n");
            return;
        },
        .missing => {
            if (require_signature) {
                std.Io.Dir.cwd().deleteFile(rt.io, update_path) catch {};
                try writer.writeAll(
                    "Signature missing or cosign unavailable. Update aborted because update_require_signature is enabled.\n",
                );
                return;
            }
            try writer.writeAll(
                "Warning: cosign signature not verified (cosign missing or signature assets absent). Proceeding; set update_require_signature=true to enforce.\n",
            );
        },
    }

    const chmod_args = [_][]const u8{ "chmod", "+x", update_path };
    _ = std.process.run(allocator, rt.io, .{
        .argv = &chmod_args,
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch {};

    std.Io.Dir.renameAbsolute(update_path, exe_path, rt.io) catch |err| {
        try writer.print("Failed to replace binary: {s}. The update was downloaded to {s}.\n", .{ @errorName(err), update_path });
        return;
    };

    try writer.print("Updated to v{s}. Restart zcode to use the new version.\n", .{remote_version});
}

fn requireSignaturePolicy(cfg_opt: ?*const config_mod.Config) bool {
    if (cfg_opt) |cfg| {
        if (cfg.update_require_signature) return true;
        if (cfg.isManagedLocked("update_require_signature")) return false;
    }
    return envFlag("ZCODE_UPDATE_REQUIRE_SIGNATURE");
}

const SignatureResult = enum { verified, mismatch, missing };

fn verifyCosignSignature(
    allocator: std.mem.Allocator,
    writer: anytype,
    asset_url: []const u8,
    artifact_path: []const u8,
) !SignatureResult {
    if (!isHttpsUrl(asset_url)) return SignatureResult.missing;

    // cosign must be on PATH; without it we cannot verify and defer
    // to the require_signature policy in cmdUpdate. Invoking cosign
    // directly avoids shell-specific PATH probes and works on both
    // macOS and Linux.
    const which = std.process.run(allocator, rt.io, .{
        .argv = &[_][]const u8{ "cosign", "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return SignatureResult.missing;
    defer allocator.free(which.stdout);
    defer allocator.free(which.stderr);
    switch (which.term) {
        .exited => |code| if (code != 0) return SignatureResult.missing,
        else => return SignatureResult.missing,
    }

    const bundle_url = try std.fmt.allocPrint(allocator, "{s}.bundle", .{asset_url});
    defer allocator.free(bundle_url);
    const bundle_path = try std.fmt.allocPrint(allocator, "{s}.bundle", .{artifact_path});
    defer allocator.free(bundle_path);
    defer std.Io.Dir.cwd().deleteFile(rt.io, bundle_path) catch {};

    if (downloadViaCurl(allocator, bundle_url, bundle_path)) |_| {
        try writer.writeAll("Verifying cosign bundle...\n");
        const argv = [_][]const u8{
            "cosign",                        "verify-blob",
            "--bundle",                      bundle_path,
            "--certificate-identity-regexp", cosign_identity_regexp,
            "--certificate-oidc-issuer",     cosign_oidc_issuer,
            artifact_path,
        };
        const verify = std.process.run(allocator, rt.io, .{
            .argv = &argv,
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
        }) catch return SignatureResult.mismatch;
        defer allocator.free(verify.stdout);
        defer allocator.free(verify.stderr);

        switch (verify.term) {
            .exited => |code| if (code == 0) {
                try writer.writeAll("Cosign bundle verified.\n");
                return SignatureResult.verified;
            } else return SignatureResult.mismatch,
            else => return SignatureResult.mismatch,
        }
    } else |_| {}

    const sig_url = try std.fmt.allocPrint(allocator, "{s}.sig", .{asset_url});
    defer allocator.free(sig_url);
    const pem_url = try std.fmt.allocPrint(allocator, "{s}.pem", .{asset_url});
    defer allocator.free(pem_url);

    const sig_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{artifact_path});
    defer allocator.free(sig_path);
    const pem_path = try std.fmt.allocPrint(allocator, "{s}.pem", .{artifact_path});
    defer allocator.free(pem_path);
    defer std.Io.Dir.cwd().deleteFile(rt.io, sig_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(rt.io, pem_path) catch {};

    downloadViaCurl(allocator, sig_url, sig_path) catch return SignatureResult.missing;
    downloadViaCurl(allocator, pem_url, pem_path) catch return SignatureResult.missing;

    try writer.writeAll("Verifying cosign signature...\n");

    const argv = [_][]const u8{
        "cosign",                        "verify-blob",
        "--certificate",                 pem_path,
        "--signature",                   sig_path,
        "--certificate-identity-regexp", cosign_identity_regexp,
        "--certificate-oidc-issuer",     cosign_oidc_issuer,
        artifact_path,
    };
    const verify = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return SignatureResult.mismatch;
    defer allocator.free(verify.stdout);
    defer allocator.free(verify.stderr);

    switch (verify.term) {
        .exited => |code| if (code == 0) {
            try writer.writeAll("Cosign signature verified.\n");
            return SignatureResult.verified;
        } else return SignatureResult.mismatch,
        else => return SignatureResult.mismatch,
    }
}

fn downloadViaCurl(allocator: std.mem.Allocator, url: []const u8, output_path: []const u8) !void {
    if (!isHttpsUrl(url)) return error.NonHttpsUpdateUrl;
    // Defense-in-depth: also gate on the central egress policy.
    // The signature/cert URLs come from the manifest (already
    // gated), but a compromised manifest pointing them at a
    // link-local target would otherwise pass isHttpsUrl and let
    // zcode hit cloud metadata via the cosign-fetch path.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.NonHttpsUpdateUrl,
    }
    // Bound the curl. Cosign sig/cert artifacts are tiny (a few KB)
    // so 60s total is plenty; without a cap, a hung mirror would
    // block the whole update flow.
    const argv = [_][]const u8{
        "curl",              "-fsSL",
        "--proto",           "=https",
        "--proto-redir",     "=https",
        "--connect-timeout", "10",
        "--max-time",        "60",
        "-o",                output_path,
        url,
    };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.DownloadFailed,
        else => return error.DownloadFailed,
    }
}

fn pinnedUpdateVersion(cfg_opt: ?*const config_mod.Config) ?[]const u8 {
    if (cfg_opt) |cfg| {
        if (cfg.update_pinned_version.len > 0) return trimVersionPrefix(cfg.update_pinned_version);
        if (cfg.isManagedLocked("update_pinned_version")) return null;
    }
    const raw = @import("core/env.zig").getenv("ZCODE_UPDATE_PINNED_VERSION") orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimVersionPrefix(trimmed);
}

fn fetchPreferredReleaseInfo(allocator: std.mem.Allocator, asset_name: []const u8) !ReleaseInfo {
    const manifest_url = try updateManifestUrl(allocator);
    defer allocator.free(manifest_url);

    if (fetchReleaseInfoFromManifest(allocator, manifest_url, asset_name)) |release_info| {
        return release_info;
    } else |_| {}

    return fetchReleaseInfoFromGithubApi(allocator, asset_name);
}

fn fetchReleaseInfoFromManifest(allocator: std.mem.Allocator, manifest_url: []const u8, asset_name: []const u8) !ReleaseInfo {
    const manifest_json = try fetchUrlViaCurl(allocator, manifest_url, 512 * 1024);
    defer allocator.free(manifest_json);
    return parseReleaseInfoFromManifestJson(allocator, manifest_json, asset_name);
}

fn fetchReleaseInfoFromGithubApi(allocator: std.mem.Allocator, asset_name: []const u8) !ReleaseInfo {
    const release_json = try fetchUrlViaCurlWithAccept(allocator, default_release_api_url, 256 * 1024, "application/vnd.github+json");
    defer allocator.free(release_json);
    return parseReleaseInfoFromGithubApiJson(allocator, release_json, asset_name);
}

fn parseReleaseInfoFromManifestJson(allocator: std.mem.Allocator, manifest_json: []const u8, asset_name: []const u8) !ReleaseInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, manifest_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidReleaseManifest;

    const version = try allocator.dupe(u8, trimVersionPrefix(getObjectString(parsed.value.object, "version") orelse return error.InvalidReleaseManifest));
    errdefer allocator.free(version);

    const checksums_url = if (getObjectString(parsed.value.object, "checksums_url")) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (checksums_url) |value| allocator.free(value);

    const assets_value = parsed.value.object.get("assets") orelse return error.InvalidReleaseManifest;
    if (assets_value != .array) return error.InvalidReleaseManifest;

    for (assets_value.array.items) |asset| {
        if (asset != .object) continue;
        const name = getObjectString(asset.object, "name") orelse continue;
        if (!std.mem.eql(u8, name, asset_name)) continue;

        const url = getObjectString(asset.object, "url") orelse continue;
        const sha256 = getObjectString(asset.object, "sha256");
        return .{
            .version = version,
            .asset_url = try allocator.dupe(u8, url),
            .checksum = if (sha256) |value| try allocator.dupe(u8, value) else null,
            .checksum_manifest_url = checksums_url,
            .source = .manifest,
        };
    }

    allocator.free(version);
    if (checksums_url) |value| allocator.free(value);
    return error.AssetNotFound;
}

fn parseReleaseInfoFromGithubApiJson(allocator: std.mem.Allocator, release_json: []const u8, asset_name: []const u8) !ReleaseInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, release_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidReleaseManifest;

    const version = try allocator.dupe(u8, trimVersionPrefix(getObjectString(parsed.value.object, "tag_name") orelse return error.InvalidReleaseManifest));
    errdefer allocator.free(version);

    const assets = parsed.value.object.get("assets") orelse return error.InvalidReleaseManifest;
    if (assets != .array) return error.InvalidReleaseManifest;

    var asset_url: ?[]u8 = null;
    errdefer if (asset_url) |value| allocator.free(value);
    var checksum_manifest_url: ?[]u8 = null;
    errdefer if (checksum_manifest_url) |value| allocator.free(value);

    for (assets.array.items) |asset| {
        if (asset != .object) continue;
        const name = getObjectString(asset.object, "name") orelse continue;
        const url = getObjectString(asset.object, "browser_download_url") orelse continue;

        if (std.mem.eql(u8, name, asset_name)) {
            asset_url = try allocator.dupe(u8, url);
        } else if (checksum_manifest_url == null and looksLikeChecksumManifest(name)) {
            checksum_manifest_url = try allocator.dupe(u8, url);
        }
    }

    const chosen_url = asset_url orelse {
        allocator.free(version);
        if (checksum_manifest_url) |value| allocator.free(value);
        return error.AssetNotFound;
    };

    return .{
        .version = version,
        .asset_url = chosen_url,
        .checksum = null,
        .checksum_manifest_url = checksum_manifest_url,
        .source = .github_api,
    };
}

fn updateManifestUrl(allocator: std.mem.Allocator) ![]u8 {
    if (@import("core/env.zig").getenv("ZCODE_UPDATE_MANIFEST_URL")) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            // Only accept https:// overrides. An attacker who can set an
            // env var in the operator's shell could otherwise point zcode
            // at http://evil/manifest.json and substitute both the manifest
            // and the binary it describes (the checksum is read from the
            // same manifest, so it provides no integrity without a pinned
            // trusted transport).
            if (!isHttpsUrl(trimmed)) return error.NonHttpsUpdateUrl;
            return allocator.dupe(u8, trimmed);
        }
    }
    return allocator.dupe(u8, default_update_manifest_url);
}

/// Return true if `url` is absolute and uses https:// (localhost exempted so
/// automated tests can point at a local test server).
fn isHttpsUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "https://")) return true;
    if (std.mem.startsWith(u8, url, "http://127.0.0.1")) return true;
    if (std.mem.startsWith(u8, url, "http://localhost")) return true;
    return false;
}

fn fetchUrlViaCurl(allocator: std.mem.Allocator, url: []const u8, max_output_bytes: usize) ![]u8 {
    return fetchUrlViaCurlWithAccept(allocator, url, max_output_bytes, null);
}

fn fetchUrlViaCurlWithAccept(allocator: std.mem.Allocator, url: []const u8, max_output_bytes: usize, accept_header: ?[]const u8) ![]u8 {
    // Refuse to fetch anything that isn't HTTPS. The manifest and asset
    // checksum flow relies on transport integrity; downgrading to HTTP
    // lets a MITM swap both the manifest and the binary. Localhost is
    // exempted for automated tests.
    if (!isHttpsUrl(url)) return error.NonHttpsUpdateUrl;
    // Also gate on the central egress policy so SSRF targets are
    // refused even when ZCODE_UPDATE_MANIFEST_URL is operator-set.
    // Without this, an env override pointing at
    // https://169.254.169.254/latest/meta-data/iam/... would pass
    // the scheme check and let zcode fetch cloud-metadata through
    // the updater path.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.NonHttpsUpdateUrl,
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    var accept_owned: ?[]u8 = null;
    defer if (accept_owned) |a| allocator.free(a);

    // Manifest / GitHub API / checksum-manifest fetches: small JSON
    // bodies, so 30s total is generous. Without --max-time a hung
    // GitHub mirror or DNS-poisoned manifest URL blocks the whole
    // update-check at startup.
    try argv.appendSlice(&.{
        "curl",              "-fsSL",
        "--proto",           "=https",
        "--proto-redir",     "=https",
        "--connect-timeout", "10",
        "--max-time",        "30",
    });
    if (accept_header) |header| {
        try argv.append("-H");
        accept_owned = try std.fmt.allocPrint(allocator, "Accept: {s}", .{header});
        try argv.append(accept_owned.?);
    }
    try argv.append(url);

    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(max_output_bytes),
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.UpdateFetchFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.UpdateFetchFailed;
        },
    }

    return result.stdout;
}

fn trimVersionPrefix(version: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, version, "v")) version[1..] else version;
}

fn getObjectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn looksLikeChecksumManifest(name: []const u8) bool {
    return parse_helpers.containsIgnoreCase(name, "sha256") or
        parse_helpers.containsIgnoreCase(name, "checksum");
}

fn extractChecksumForAsset(allocator: std.mem.Allocator, manifest: []const u8, asset_name: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "SHA256(") and std.mem.indexOf(u8, line, ")=") != null) {
            const close_idx = std.mem.indexOf(u8, line, ")=").?;
            const file_name = std.mem.trim(u8, line["SHA256(".len..close_idx], " \t");
            const hash = std.mem.trim(u8, line[close_idx + 2 ..], " \t");
            if (std.mem.eql(u8, file_name, asset_name) and isHexLen(hash, 64)) {
                return @as(?[]u8, try allocator.dupe(u8, hash));
            }
            continue;
        }

        var tok = std.mem.tokenizeAny(u8, line, " \t");
        const hash = tok.next() orelse continue;
        var file_name = tok.next() orelse continue;
        if (file_name.len > 0 and file_name[0] == '*') file_name = file_name[1..];
        if (std.mem.eql(u8, file_name, asset_name) and isHexLen(hash, 64)) {
            return @as(?[]u8, try allocator.dupe(u8, hash));
        }
    }

    return null;
}

fn isHexLen(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(data);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, digest.len * 2);
    errdefer allocator.free(out);
    for (digest, 0..) |b, idx| {
        out[idx * 2] = alphabet[@as(usize, b >> 4)];
        out[idx * 2 + 1] = alphabet[@as(usize, b & 0x0f)];
    }
    return out;
}

fn envFlag(name: []const u8) bool {
    const ptr = @import("core/env.zig").getenv(name) orelse return false;
    const value = std.mem.trim(u8, ptr, " \t\r\n");
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const parsed_a = std.SemanticVersion.parse(a) catch return std.mem.order(u8, a, b);
    const parsed_b = std.SemanticVersion.parse(b) catch return std.mem.order(u8, a, b);
    return parsed_a.order(parsed_b);
}

const testing = std.testing;

test "compareVersions handles semver ordering" {
    try testing.expect(compareVersions("0.5.0", "0.5.0") == .eq);
    try testing.expect(compareVersions("0.5.1", "0.5.0") == .gt);
    try testing.expect(compareVersions("0.4.17", "0.5.0") == .lt);
}

test "parse manifest release info prefers inline asset checksum" {
    const raw =
        \\{
        \\  "version": "v1.2.3",
        \\  "checksums_url": "https://example.test/SHA256SUMS",
        \\  "assets": [
        \\    {
        \\      "name": "zcode-linux-x86_64",
        \\      "url": "https://example.test/zcode-linux-x86_64",
        \\      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseReleaseInfoFromManifestJson(testing.allocator, raw, "zcode-linux-x86_64");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("1.2.3", parsed.version);
    try testing.expectEqualStrings("https://example.test/zcode-linux-x86_64", parsed.asset_url);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", parsed.checksum.?);
    try testing.expectEqualStrings("https://example.test/SHA256SUMS", parsed.checksum_manifest_url.?);
    try testing.expect(parsed.source == .manifest);
}

test "parse github api release info finds checksum manifest fallback" {
    const raw =
        \\{
        \\  "tag_name": "v2.0.0",
        \\  "assets": [
        \\    {
        \\      "name": "zcode-linux-x86_64",
        \\      "browser_download_url": "https://example.test/zcode-linux-x86_64"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS",
        \\      "browser_download_url": "https://example.test/SHA256SUMS"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseReleaseInfoFromGithubApiJson(testing.allocator, raw, "zcode-linux-x86_64");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqualStrings("2.0.0", parsed.version);
    try testing.expectEqualStrings("https://example.test/zcode-linux-x86_64", parsed.asset_url);
    try testing.expect(parsed.checksum == null);
    try testing.expectEqualStrings("https://example.test/SHA256SUMS", parsed.checksum_manifest_url.?);
    try testing.expect(parsed.source == .github_api);
}
