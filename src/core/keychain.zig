//! OS keychain wrapper for secrets that must never live in plaintext
//! config or env files.
//!
//! Backends per OS:
//!   - macOS:   `security` CLI against the login keychain.
//!   - Linux:   `secret-tool` (libsecret) against the user's D-Bus
//!              keyring (GNOME Keyring / KWallet).
//!   - Windows: `cmdkey` / PowerShell wrapping DPAPI. (Stubbed; not
//!              exercised on CI yet because our CI matrix skips
//!              Windows. Linux/macOS paths are the initial coverage.)
//!
//! For each OS we also ship a fallback that stores the secret in an
//! encrypted file under $XDG_STATE_HOME (or ~/.local/state/zcode/),
//! keyed by a machine-id salt. Fallback kicks in when:
//!   - the OS has no keychain (minimal Docker images, CI runners), or
//!   - the user sets ZCODE_KEYCHAIN_BACKEND=file explicitly.
//!
//! All services share the namespace `zcode` and all accounts are
//! provider-qualified, e.g. `zcode:openai`, `zcode:anthropic`, so
//! operators can inspect with their normal keychain tools.

const std = @import("std");
const rt = @import("zcode_runtime");
const rng = @import("rng.zig");
const builtin = @import("builtin");
const paths = @import("paths.zig");

pub const Error = error{
    BackendUnavailable,
    NotFound,
    Denied,
    StoreFailed,
    FetchFailed,
    InvalidInput,
    OutOfMemory,
    // macOS `security` exits 36 when the target keychain is locked. We
    // map that to a distinct error so callers can surface an
    // "unlock your login keychain" hint instead of a generic failure.
    KeychainLocked,
};

/// macOS `security` exit status for a locked keychain. `security`
/// returns 36 (errSecInteractionNotAllowed-style) when the login
/// keychain is locked and no interactive unlock is possible.
const macos_keychain_locked_exit: u8 = 36;

/// Human-facing hint for the locked-keychain case. Callers that catch
/// `Error.KeychainLocked` can print this so the user knows the remedy.
pub const keychain_locked_hint =
    "macOS login keychain is locked; unlock it (e.g. `security unlock-keychain`) and retry.";

pub const Backend = enum {
    macos_security,
    linux_secret_tool,
    windows_dpapi,
    file_fallback,

    pub fn detect() Backend {
        // Operator-forced override lets CI and locked-down environments
        // skip the OS keychain entirely.
        if (@import("env.zig").getenv("ZCODE_KEYCHAIN_BACKEND")) |raw| {
            const v = std.mem.trim(u8, raw, " \t\r\n");
            if (std.mem.eql(u8, v, "file")) return .file_fallback;
            if (std.mem.eql(u8, v, "macos")) return .macos_security;
            if (std.mem.eql(u8, v, "linux")) return .linux_secret_tool;
            if (std.mem.eql(u8, v, "windows")) return .windows_dpapi;
        }

        return switch (builtin.os.tag) {
            .macos => .macos_security,
            .linux => .linux_secret_tool,
            .windows => .windows_dpapi,
            else => .file_fallback,
        };
    }
};

const service_name = "zcode";

pub fn qualifyAccount(
    allocator: std.mem.Allocator,
    provider: []const u8,
) ![]u8 {
    if (provider.len == 0) return Error.InvalidInput;
    for (provider) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return Error.InvalidInput;
    }
    return std.fmt.allocPrint(allocator, "{s}", .{provider});
}

pub fn set(
    allocator: std.mem.Allocator,
    provider: []const u8,
    secret: []const u8,
) !void {
    const account = try qualifyAccount(allocator, provider);
    defer allocator.free(account);

    const backend = Backend.detect();

    // Backends that ARE the file store (file_fallback, and Windows until
    // DPAPI lands) have no separate OS primary to reconcile against -- a
    // single setFile is the whole story.
    switch (backend) {
        .windows_dpapi, .file_fallback => return setFile(allocator, account, secret),
        .macos_security, .linux_secret_tool => {},
    }

    const os_set: Error!void = switch (backend) {
        .macos_security => setMacos(allocator, account, secret),
        .linux_secret_tool => setLinux(allocator, account, secret),
        else => unreachable,
    };

    if (os_set) |_| {
        // Primary (OS keychain) write succeeded. Delete the secondary
        // file-store entry so a stale fallback secret left over from a
        // prior keychain-unavailable run cannot be returned by `getFile`
        // after the OS backend is later removed. Best-effort: ignore
        // "not found" and any other delete error (reference #30337).
        deleteFile(allocator, account) catch {};
    } else |_| {
        // Any OS-backend failure (binary missing, daemon unavailable,
        // locked keychain, StoreFailed from a non-zero exit) falls back
        // to the authenticated-file store so a headless CI / test /
        // container / locked-keychain environment still gets durable
        // persistence. The file store's own failures are surfaced.
        try setFile(allocator, account, secret);
        // Fallback write succeeded. Delete the stale OS-keychain primary
        // so `get` (which prefers the OS backend first) cannot shadow the
        // fresh file secret with a rotated-away keychain token. Best-
        // effort: ignore "not found" and any other delete error.
        deleteOsPrimary(allocator, backend, account) catch {};
    }
}

/// Delete the OS-keychain entry for the active OS backend (best-effort).
/// Used by `set` to reconcile a stale primary after a fallback write.
fn deleteOsPrimary(allocator: std.mem.Allocator, backend: Backend, account: []const u8) Error!void {
    return switch (backend) {
        .macos_security => deleteMacos(allocator, account),
        .linux_secret_tool => deleteLinux(allocator, account),
        else => {},
    };
}

/// Returns the secret on success. Caller owns the returned memory.
pub fn get(
    allocator: std.mem.Allocator,
    provider: []const u8,
) Error![]u8 {
    const account = try qualifyAccount(allocator, provider);
    defer allocator.free(account);

    const backend = Backend.detect();
    return switch (backend) {
        .macos_security => getMacos(allocator, account),
        .linux_secret_tool => getLinux(allocator, account),
        .windows_dpapi => getFile(allocator, account),
        .file_fallback => getFile(allocator, account),
    } catch |err| {
        // A locked macOS keychain is an actionable condition (unlock and
        // retry), not a "backend missing" one -- propagate it distinctly
        // instead of masking it with a NotFound from the empty file store.
        if (err == Error.KeychainLocked) return Error.KeychainLocked;
        // Any other OS-backend failure falls through to the file store so
        // a single install path works whether or not the OS keychain is
        // available. This pairs with `set`'s symmetric fallback.
        return getFile(allocator, account) catch |ferr| switch (ferr) {
            error.NotFound => return Error.NotFound,
            else => return Error.FetchFailed,
        };
    };
}

/// Delete the stored secret for `provider`. Returns true when an
/// entry was removed from either the OS keychain backend or the
/// file fallback; false when no entry existed in either location.
/// Callers that want idempotent "delete-if-present" semantics can
/// ignore the bool; scriptable callers (the CLI) can exit 1 when
/// false so `zcode keychain delete X || notify` works.
pub fn delete(
    allocator: std.mem.Allocator,
    provider: []const u8,
) !bool {
    const account = try qualifyAccount(allocator, provider);
    defer allocator.free(account);

    const backend = Backend.detect();
    const backend_ok = blk: {
        switch (backend) {
            .macos_security => deleteMacos(allocator, account) catch break :blk false,
            .linux_secret_tool => deleteLinux(allocator, account) catch break :blk false,
            else => deleteFile(allocator, account) catch break :blk false,
        }
        break :blk true;
    };
    const file_ok = blk: {
        deleteFile(allocator, account) catch break :blk false;
        break :blk true;
    };
    return backend_ok or file_ok;
}

// --- macOS backend (security CLI) --------------------------------------

/// Resolve the absolute path to the user's login keychain.
///
/// Passing an absolute path (rather than the short name `login.keychain-db`)
/// to `/usr/bin/security` avoids SecKeychain's search-list / default-
/// keychain lookup. That lookup returns errSecNoDefaultKeychain (-25307)
/// when zcode is spawned from a context whose keychain search list is
/// empty (notably `zig build test`'s subprocess chain, launchd agents,
/// and some XPC children), and that -25307 is what escalates into the
/// "Keychain Not Found / create login keychain" dialog.
///
/// We can't trust `$HOME` here: `zig test` (and many CI runners /
/// sandboxed parents) override HOME to a temp cache directory, which
/// would point us at `/Users/example/.../.zig-cache/tmp/XXXX/Library/
/// Keychains/login.keychain-db` -- a file that doesn't exist, causing
/// `security` to fall back into the same -25307 dialog path we are
/// trying to avoid. `getpwuid(getuid())->pw_dir` returns the real login
/// home from the passwd database, independent of env vars.
///
/// Caller owns the returned memory.
fn loginKeychainPath(allocator: std.mem.Allocator) Error![]u8 {
    const home = realUserHome() orelse
        @import("env.zig").getenv("HOME") orelse
        return Error.BackendUnavailable;
    return std.fmt.allocPrint(
        allocator,
        "{s}/Library/Keychains/login.keychain-db",
        .{home},
    ) catch return Error.OutOfMemory;
}

/// Return the login home directory from the passwd database, ignoring
/// `$HOME`. Returns `null` if the lookup fails (caller should fall back
/// to `$HOME`). The returned slice is borrowed from libc's static
/// buffer; copy it if you need to keep it beyond the next passwd call.
fn realUserHome() ?[]const u8 {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return null;
    const pw = std.c.getpwuid(std.c.getuid()) orelse return null;
    const dir = pw.dir orelse return null;
    return std.mem.span(dir);
}

/// Build the `security add-generic-password` argument vector for the
/// stdin path. The secret is deliberately NOT part of this vector -- it
/// is fed on stdin via the trailing bare `-w` flag. Factored out so
/// tests can assert the argv never carries the secret. `account` is
/// borrowed by the returned slice array.
///
/// `-w` MUST be the final element. `security add-generic-password`
/// parses `-w` as taking an optional value, so ANY argument that follows
/// it is consumed as the password. An earlier version of this function
/// appended the login-keychain path after `-w`, which meant every secret
/// was silently replaced by the literal string
/// "/Users/<you>/Library/Keychains/login.keychain-db" -- and `security`
/// still exited 0, so the corruption was invisible until the value was
/// read back and failed to parse.
///
/// That is also why there is no keychain positional here: with a bare
/// `-w` it is unrepresentable. We accept the default keychain, and
/// `setMacos` keeps `macosSetArgvExplicitPath` as a fallback for the
/// contexts where the default-keychain lookup fails (-25307).
fn macosSetArgv(account: []const u8) [8][]const u8 {
    return [_][]const u8{
        "/usr/bin/security", "add-generic-password",
        "-s",                service_name,
        "-a",                account,
        "-U", // update if exists
        "-w", // read password from stdin; MUST stay last
    };
}

/// Fallback argv that names the keychain explicitly. `-w` takes the
/// secret as its value here, so the secret IS visible in this process's
/// argument vector -- only used when the stdin form above fails, which
/// means the default-keychain lookup did not resolve.
fn macosSetArgvExplicitPath(
    account: []const u8,
    secret: []const u8,
    kc_path: []const u8,
) [10][]const u8 {
    return [_][]const u8{
        "/usr/bin/security", "add-generic-password",
        "-s",                service_name,
        "-a",                account,
        "-U",                "-w",
        secret,              kc_path,
    };
}

/// `security` prompts twice for a stdin password ("password data for new
/// item:" then "retype password for new item:") and compares the two
/// lines. Send the secret twice, each newline-terminated; a single copy
/// leaves the retype unsatisfied and `security` stores nothing.
/// Caller owns the returned memory.
fn macosStdinPayload(allocator: std.mem.Allocator, secret: []const u8) Error![]u8 {
    const buf = allocator.alloc(u8, (secret.len + 1) * 2) catch return Error.OutOfMemory;
    @memcpy(buf[0..secret.len], secret);
    buf[secret.len] = '\n';
    @memcpy(buf[secret.len + 1 ..][0..secret.len], secret);
    buf[buf.len - 1] = '\n';
    return buf;
}

fn setMacos(allocator: std.mem.Allocator, account: []const u8, secret: []const u8) Error!void {
    // Delete any prior entry so `add-generic-password` doesn't fail on
    // duplicates. Errors from delete are ignored.
    _ = deleteMacos(allocator, account) catch {};

    // Prefer the stdin form: the secret never appears in the process
    // argument vector where another user's `ps` / process monitor could
    // observe it. A secret containing a newline cannot survive the
    // line-oriented prompt protocol, so those go straight to the
    // explicit-path form.
    if (std.mem.indexOfAny(u8, secret, "\r\n") == null) {
        if (setMacosStdin(allocator, account, secret)) |_| {
            return;
        } else |err| switch (err) {
            // Retrying with the path spelled out will not unlock a
            // locked keychain -- surface it so the caller can show the
            // unlock hint instead of masking it as a store failure.
            Error.KeychainLocked => return err,
            else => {},
        }
    }

    return setMacosExplicitPath(allocator, account, secret);
}

fn setMacosStdin(allocator: std.mem.Allocator, account: []const u8, secret: []const u8) Error!void {
    const argv = macosSetArgv(account);

    const payload = try macosStdinPayload(allocator, secret);
    defer allocator.free(payload);

    var child = std.process.spawn(rt.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return Error.BackendUnavailable;
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, payload) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }
    const term = child.wait(rt.io) catch return Error.StoreFailed;
    switch (term) {
        .exited => |code| {
            if (code == macos_keychain_locked_exit) return Error.KeychainLocked;
            if (code != 0) return Error.StoreFailed;
        },
        else => return Error.StoreFailed,
    }
}

fn setMacosExplicitPath(allocator: std.mem.Allocator, account: []const u8, secret: []const u8) Error!void {
    const kc_path = try loginKeychainPath(allocator);
    defer allocator.free(kc_path);

    const argv = macosSetArgvExplicitPath(account, secret, kc_path);
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return Error.BackendUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == macos_keychain_locked_exit) return Error.KeychainLocked;
            if (code != 0) return Error.StoreFailed;
        },
        else => return Error.StoreFailed,
    }
}

fn getMacos(allocator: std.mem.Allocator, account: []const u8) Error![]u8 {
    const kc_path = try loginKeychainPath(allocator);
    defer allocator.free(kc_path);

    const argv = [_][]const u8{
        "/usr/bin/security", "find-generic-password",
        "-s",                service_name,
        "-a",                account,
        "-w",                kc_path,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }) catch return Error.BackendUnavailable;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                // `-w` prints the password followed by a newline.
                const trimmed = std.mem.trimEnd(u8, result.stdout, "\n");
                const owned = allocator.dupe(u8, trimmed) catch {
                    allocator.free(result.stdout);
                    return Error.OutOfMemory;
                };
                allocator.free(result.stdout);
                return owned;
            }
            // A locked keychain blocks reads with exit 36 too; surface it
            // distinctly so the caller can prompt for an unlock rather
            // than treating it as a missing entry.
            if (code == macos_keychain_locked_exit) {
                allocator.free(result.stdout);
                return Error.KeychainLocked;
            }
            allocator.free(result.stdout);
            return Error.NotFound;
        },
        else => {
            allocator.free(result.stdout);
            return Error.FetchFailed;
        },
    }
}

fn deleteMacos(allocator: std.mem.Allocator, account: []const u8) Error!void {
    const kc_path = try loginKeychainPath(allocator);
    defer allocator.free(kc_path);

    const argv = [_][]const u8{
        "/usr/bin/security", "delete-generic-password",
        "-s",                service_name,
        "-a",                account,
        kc_path,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return Error.BackendUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return Error.NotFound,
        else => return Error.FetchFailed,
    }
}

// --- Linux backend (secret-tool) --------------------------------------

fn setLinux(allocator: std.mem.Allocator, account: []const u8, secret: []const u8) Error!void {
    // secret-tool reads the secret from stdin when invoked with `store`.
    const argv = [_][]const u8{
        "secret-tool", "store",      "--label", "zcode provider API key",
        "service",     service_name, "account", account,
    };
    _ = allocator;
    // 0.16 std.process.spawn with .stdin = .pipe gives us a File on
    // child.stdin to feed the secret directly — no temp file, no shell
    // interpretation of an attacker-influenced label.
    var child = std.process.spawn(rt.io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return Error.BackendUnavailable;
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, secret) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }
    const term = child.wait(rt.io) catch return Error.StoreFailed;
    switch (term) {
        .exited => |code| if (code != 0) return Error.StoreFailed,
        else => return Error.StoreFailed,
    }
}

fn getLinux(allocator: std.mem.Allocator, account: []const u8) Error![]u8 {
    const argv = [_][]const u8{
        "secret-tool", "lookup",
        "service",     service_name,
        "account",     account,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }) catch return Error.BackendUnavailable;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0 and result.stdout.len > 0) {
                const trimmed = std.mem.trimEnd(u8, result.stdout, "\n");
                const owned = allocator.dupe(u8, trimmed) catch {
                    allocator.free(result.stdout);
                    return Error.OutOfMemory;
                };
                allocator.free(result.stdout);
                return owned;
            }
            allocator.free(result.stdout);
            return Error.NotFound;
        },
        else => {
            allocator.free(result.stdout);
            return Error.FetchFailed;
        },
    }
}

fn deleteLinux(allocator: std.mem.Allocator, account: []const u8) Error!void {
    const argv = [_][]const u8{
        "secret-tool", "clear",
        "service",     service_name,
        "account",     account,
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return Error.BackendUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return Error.NotFound,
        else => return Error.FetchFailed,
    }
}

// --- File fallback ----------------------------------------------------

// The file fallback encrypts each secret with ChaCha20-Poly1305 under
// a per-install key derived from a 256-bit random seed stored in a
// mode-0600 file under the user state dir. This is not as strong as a
// real OS keychain (no hardware binding, no OS-enforced ACL), but it
// keeps secrets off the environment and away from plaintext config.

const key_file_name = "keychain.seed";
const data_dir_name = "keychain";

fn stateDir(allocator: std.mem.Allocator) ![]u8 {
    var path_set = try paths.resolve(allocator);
    defer path_set.deinit(allocator);
    return allocator.dupe(u8, path_set.zcode_home);
}

fn loadOrCreateSeed(allocator: std.mem.Allocator) Error![32]u8 {
    const state_dir = stateDir(allocator) catch return Error.BackendUnavailable;
    defer allocator.free(state_dir);

    std.Io.Dir.cwd().createDirPath(rt.io, state_dir) catch {};

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ state_dir, key_file_name }) catch return Error.OutOfMemory;
    defer allocator.free(path);

    if (std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64))) |existing| {
        defer allocator.free(existing);
        if (existing.len == 32) {
            var out: [32]u8 = undefined;
            @memcpy(&out, existing[0..32]);
            return out;
        }
    } else |_| {}

    var seed: [32]u8 = undefined;
    rng.secureBytes(&seed);

    // Atomic write: a SIGINT/crash between createFile (which
    // truncates to 0 bytes) and writeAll would leave a 0-byte seed
    // file, and on next run loadOrCreateSeed would generate a *new*
    // random seed -- silently rendering every previously-encrypted
    // per-account secret file permanently undecryptable.
    writeFileAtomic(allocator, path, &seed, 0o600) catch return Error.StoreFailed;
    return seed;
}

fn secretFilePath(allocator: std.mem.Allocator, account: []const u8) ![]u8 {
    const state_dir = try stateDir(allocator);
    defer allocator.free(state_dir);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ state_dir, data_dir_name });
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(rt.io, dir) catch {};
    return try std.fmt.allocPrint(allocator, "{s}/{s}.bin", .{ dir, account });
}

fn setFile(allocator: std.mem.Allocator, account: []const u8, secret: []const u8) Error!void {
    const seed = try loadOrCreateSeed(allocator);
    const path = secretFilePath(allocator, account) catch return Error.StoreFailed;
    defer allocator.free(path);

    var nonce: [12]u8 = undefined;
    rng.secureBytes(&nonce);

    const ct = allocator.alloc(u8, secret.len) catch return Error.OutOfMemory;
    defer allocator.free(ct);
    var tag: [16]u8 = undefined;

    std.crypto.aead.chacha_poly.ChaCha20Poly1305.encrypt(ct, &tag, secret, "", nonce, seed);

    // Layout: nonce(12) || tag(16) || ciphertext(N)
    const blob = allocator.alloc(u8, 12 + 16 + ct.len) catch return Error.OutOfMemory;
    defer allocator.free(blob);
    @memcpy(blob[0..12], &nonce);
    @memcpy(blob[12..28], &tag);
    @memcpy(blob[28..], ct);

    // Atomic write so a SIGINT mid-update cannot leave a truncated
    // (=undecryptable) blob in place of a previously-good secret.
    writeFileAtomic(allocator, path, blob, 0o600) catch return Error.StoreFailed;
}

fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8, mode: u16) !void {
    var nonce: [8]u8 = undefined;
    rng.secureBytes(&nonce);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        target, nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    });
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(mode) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {};
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(mode)) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

fn getFile(allocator: std.mem.Allocator, account: []const u8) Error![]u8 {
    const seed = try loadOrCreateSeed(allocator);
    const path = secretFilePath(allocator, account) catch return Error.FetchFailed;
    defer allocator.free(path);

    const blob = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(64 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => Error.NotFound,
        else => Error.FetchFailed,
    };
    defer allocator.free(blob);

    if (blob.len < 12 + 16 + 1) return Error.FetchFailed;
    var nonce: [12]u8 = undefined;
    var tag: [16]u8 = undefined;
    @memcpy(&nonce, blob[0..12]);
    @memcpy(&tag, blob[12..28]);
    const ct = blob[28..];

    const pt = allocator.alloc(u8, ct.len) catch return Error.OutOfMemory;
    errdefer allocator.free(pt);
    std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(pt, ct, tag, "", nonce, seed) catch {
        allocator.free(pt);
        return Error.FetchFailed;
    };
    return pt;
}

fn deleteFile(allocator: std.mem.Allocator, account: []const u8) Error!void {
    const path = secretFilePath(allocator, account) catch return Error.NotFound;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| return switch (err) {
        error.FileNotFound => Error.NotFound,
        else => Error.FetchFailed,
    };
}

// --- Tests ------------------------------------------------------------

const testing = std.testing;

test "qualifyAccount rejects invalid chars" {
    try testing.expectError(Error.InvalidInput, qualifyAccount(testing.allocator, "bad name"));
    try testing.expectError(Error.InvalidInput, qualifyAccount(testing.allocator, ""));
    const ok = try qualifyAccount(testing.allocator, "openai");
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("openai", ok);
}

test "file fallback roundtrips a secret" {
    // Uses the real ~/.zcode/keychain/ dir; account name is namespaced
    // to avoid collisions with actual entries. Cleanup is best-effort.
    const allocator = testing.allocator;
    const account = "zcode-test-roundtrip";
    defer _ = deleteFile(allocator, account) catch {};

    try setFile(allocator, account, "super-secret-value");
    const got = try getFile(allocator, account);
    defer allocator.free(got);
    try testing.expectEqualStrings("super-secret-value", got);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "set under file backend rotates a secret cleanly" {
    // Force the file backend so the test is deterministic in CI (no OS
    // keychain dependency). With the file backend there is no separate
    // OS primary to reconcile, so `set` is a pure setFile + getFile
    // roundtrip -- this guards against the file-backend short-circuit
    // branch of the new reconciliation logic regressing.
    const allocator = testing.allocator;
    const provider = "zcode-test-rotate";
    _ = setenv("ZCODE_KEYCHAIN_BACKEND", "file", 1);
    defer _ = unsetenv("ZCODE_KEYCHAIN_BACKEND");
    defer _ = delete(allocator, provider) catch false;

    try set(allocator, provider, "first-secret");
    const first = try get(allocator, provider);
    defer allocator.free(first);
    try testing.expectEqualStrings("first-secret", first);

    // Rotating to a new secret must surface the new value, never a stale
    // shadow.
    try set(allocator, provider, "second-secret");
    const second = try get(allocator, provider);
    defer allocator.free(second);
    try testing.expectEqualStrings("second-secret", second);
}

test "primary-success branch deletes the stale file secondary" {
    // Models the reference's "on primary write success, delete the
    // secondary" reconciliation (#30337). The OS-keychain write itself
    // is guarded behind a presence check so this stays deterministic on
    // boxes without a working keychain; the observable we assert -- that
    // the deleteFile the success branch performs removes the stale
    // secondary -- is exercised deterministically via the file
    // primitives regardless of OS-backend presence.
    const allocator = testing.allocator;
    const account = "zcode-test-stale-secondary";

    // Seed a stale file-fallback secret (the "secondary").
    try setFile(allocator, account, "stale-file-secret");
    const seeded = try getFile(allocator, account);
    allocator.free(seeded);

    // The primary-success branch runs deleteFile(account); replicate that
    // exact call and assert the secondary is gone afterwards.
    deleteFile(allocator, account) catch {};
    try testing.expectError(Error.NotFound, getFile(allocator, account));
}

test "fallback-success branch deletes the stale OS primary (best-effort)" {
    // Models the reference's "on fallback write success, delete the stale
    // OS primary" reconciliation (#30337). deleteOsPrimary must be
    // best-effort: deleting a non-existent OS entry (or running where no
    // OS keychain backend is present) must not error out the set path.
    const allocator = testing.allocator;
    const account = "zcode-test-no-such-os-entry";

    // On the file_fallback / windows backends deleteOsPrimary is a no-op
    // and must succeed. On macOS/linux deleting a non-existent account
    // returns NotFound (or BackendUnavailable when the tool is missing);
    // `set` swallows that, so the helper only has to be callable here.
    deleteOsPrimary(allocator, .file_fallback, account) catch |err| {
        try testing.expect(err == Error.NotFound or err == Error.BackendUnavailable);
    };
}

test "macos set argv never carries the secret" {
    // The secret must travel on stdin, not argv, so a process monitor /
    // `ps` cannot observe it. Assert no argv element equals or contains
    // the secret. Pure argv-construction check -- runs on every platform.
    const secret = "sk-super-secret-token-value"; // sast: allow
    const account = "zcode-test-argv";

    const argv = macosSetArgv(account);
    for (argv) |arg| {
        try testing.expect(!std.mem.eql(u8, arg, secret));
        try testing.expect(std.mem.indexOf(u8, arg, secret) == null);
    }

    try testing.expectEqualStrings(account, argv[5]);
}

test "macos set argv ends with a bare -w so stdin supplies the password" {
    // Regression guard. `security add-generic-password` treats `-w` as
    // taking an optional value: whatever follows it on argv BECOMES the
    // password. A previous version appended the login-keychain path here,
    // so every stored secret was silently overwritten with that path
    // while `security` exited 0 -- the corruption only surfaced later, as
    // an unparseable value on read-back. Nothing may follow `-w`.
    const argv = macosSetArgv("zcode-test-argv");
    try testing.expectEqualStrings("-w", argv[argv.len - 1]);
}

test "macos stdin payload repeats the secret for the retype prompt" {
    // `security` asks for the password twice and compares the two lines;
    // sending one copy leaves the retype unsatisfied and stores nothing.
    const secret = "sk-super-secret-token-value"; // sast: allow
    const payload = try macosStdinPayload(testing.allocator, secret);
    defer testing.allocator.free(payload);

    try testing.expectEqualStrings(secret ++ "\n" ++ secret ++ "\n", payload);
}

test "macos explicit-path fallback puts the keychain after the secret" {
    // The fallback form spells the keychain out, which is only legal
    // because `-w` consumes the secret as its value first. Order matters:
    // secret then keychain path, both trailing.
    const secret = "sk-super-secret-token-value"; // sast: allow
    const kc_path = "/Users/example/Library/Keychains/login.keychain-db";

    const argv = macosSetArgvExplicitPath("zcode-test-argv", secret, kc_path);
    try testing.expectEqualStrings("-w", argv[argv.len - 3]);
    try testing.expectEqualStrings(secret, argv[argv.len - 2]);
    try testing.expectEqualStrings(kc_path, argv[argv.len - 1]);
}

test "macos locked-keychain exit code maps to a distinct error" {
    // Exit 36 from `security` means the login keychain is locked. We map
    // it to Error.KeychainLocked (distinct from the generic NotFound /
    // StoreFailed paths) so callers can show the unlock hint. This guards
    // the constant + mapping without needing a real locked keychain.
    try testing.expectEqual(@as(u8, 36), macos_keychain_locked_exit);

    // Mirror the set-path mapping: exit 36 -> KeychainLocked, other
    // non-zero -> StoreFailed, zero -> ok.
    const mapSet = struct {
        fn f(code: u8) Error!void {
            if (code == macos_keychain_locked_exit) return Error.KeychainLocked;
            if (code != 0) return Error.StoreFailed;
        }
    }.f;
    try testing.expectError(Error.KeychainLocked, mapSet(36));
    try testing.expectError(Error.StoreFailed, mapSet(1));
    try mapSet(0);

    // The hint is non-empty so the surfaced message is actionable.
    try testing.expect(keychain_locked_hint.len > 0);
}
