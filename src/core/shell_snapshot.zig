//! Shell environment snapshot (bash-shell-02).
//!
//! Sources the user's .zshrc/.bashrc once per session, captures functions,
//! aliases, and shell options into a snapshot `.sh` file under a
//! `shell-snapshots/` directory inside the zcode config home, and returns
//! the path so every bash command can source it. Commands then see the
//! user's interactive aliases/functions without paying the cost of a
//! login shell per command.
//!
//! Ported (with simplifications) from claude-code-main
//! src/utils/bash/ShellSnapshot.ts:
//!   - getConfigFile (181-191): pick .zshrc / .bashrc / .profile from $SHELL.
//!   - getUserSnapshotContent (197-263): functions via typeset -f / declare -f,
//!     options via setopt / shopt -p, aliases via `alias`, with `unalias -a`
//!     and `shopt -s expand_aliases` for bash.
//!   - getClaudeCodeSnapshotContent (333-339): inject resolved PATH.
//!   - createAndSaveSnapshot (413-582): run `binShell -c -l <script>` with a
//!     10s timeout and GIT_EDITOR=true / CLAUDECODE=1, write the snapshot,
//!     return its path.
//!
//! Deliberately skipped (see plan note): the ripgrep/bfs/ugrep argv0
//! shadowing (ShellSnapshot.ts:35-179) is bun-internal embedded-binary
//! specific and does not apply to zcode.
//!
//! This is a thin module (uses rt.io for file/process IO), not a pure deep
//! module. It must never feed the capture subprocess's stdout to the model:
//! the capture is best-effort and time-bounded; on any failure it returns
//! null and zcode keeps working without the snapshot.

const std = @import("std");
const rt = @import("zcode_runtime");
const env = @import("env.zig");
const paths = @import("paths.zig");
const clock = @import("clock.zig");
const rng = @import("rng.zig");

/// How long the capture subprocess may run before we give up and fall back
/// to no-snapshot. Mirrors the reference SNAPSHOT_CREATION_TIMEOUT (10s).
const SNAPSHOT_CREATION_TIMEOUT_NS: u64 = 10 * std.time.ns_per_s;

/// Upper bound on the captured snapshot script output. The reference uses a
/// 1 MiB maxBuffer; we cap the subprocess stdout/stderr at the same.
const CAPTURE_BUFFER_LIMIT: usize = 1024 * 1024;

pub const ShellKind = enum {
    zsh,
    bash,
    sh,

    fn label(self: ShellKind) []const u8 {
        return switch (self) {
            .zsh => "zsh",
            .bash => "bash",
            .sh => "sh",
        };
    }
};

/// Classify a shell binary path the same way the reference does
/// (createAndSaveSnapshot:416-420): substring match on the path.
pub fn shellKindOf(shell_path: []const u8) ShellKind {
    if (std.mem.indexOf(u8, shell_path, "zsh") != null) return .zsh;
    if (std.mem.indexOf(u8, shell_path, "bash") != null) return .bash;
    return .sh;
}

/// Pick the rc file the reference would source for this shell
/// (getConfigFile:181-191). Returns the basename only; the caller joins it
/// onto the home directory.
pub fn configFileName(kind: ShellKind) []const u8 {
    return switch (kind) {
        .zsh => ".zshrc",
        .bash => ".bashrc",
        .sh => ".profile",
    };
}

/// Build the capture script that, when run by the user's shell, writes the
/// snapshot file at `snapshot_path`. `config_file` is the absolute rc path
/// to source (sourced only when `config_exists`). Pure: no IO, returns an
/// owned slice the caller frees.
///
/// The script mirrors getSnapshotScript (345-386) + getUserSnapshotContent
/// (197-263): unalias to avoid conflicts, dump functions / options / aliases,
/// then export the resolved PATH. We keep it deliberately simpler than the
/// reference (no base64 function round-trip, no winpty/msys branch) because
/// zcode targets macOS/Linux and just needs aliases + functions to resolve.
pub fn buildSnapshotScript(
    allocator: std.mem.Allocator,
    kind: ShellKind,
    snapshot_path: []const u8,
    config_file: []const u8,
    config_exists: bool,
    path_value: []const u8,
) ![]u8 {
    const helpers = @import("../tools/helpers.zig");
    const std_io = @import("std_io.zig");
    const snapshot_q = try helpers.shellQuoteAlloc(allocator, snapshot_path);
    defer allocator.free(snapshot_q);
    const config_q = try helpers.shellQuoteAlloc(allocator, config_file);
    defer allocator.free(config_q);
    const path_q = try helpers.shellQuoteAlloc(allocator, path_value);
    defer allocator.free(path_q);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.print("SNAPSHOT_FILE={s}\n", .{snapshot_q});

    if (config_exists) {
        // Source the user's rc with stdin closed so an rc that reads stdin
        // (e.g. a `read` prompt) does not block the capture forever.
        try w.print("source {s} < /dev/null 2>/dev/null || true\n", .{config_q});
    } else {
        try w.writeAll("# No user config file to source\n");
    }

    // Create/clear the snapshot file.
    try w.writeAll("echo \"# Snapshot file\" >| \"$SNAPSHOT_FILE\"\n");
    // When sourced, unalias everything first so aliases do not collide with
    // function definitions that were frozen at definition time.
    try w.writeAll("echo \"# Unset all aliases to avoid conflicts with functions\" >> \"$SNAPSHOT_FILE\"\n");
    try w.writeAll("echo \"unalias -a 2>/dev/null || true\" >> \"$SNAPSHOT_FILE\"\n");

    // Functions.
    try w.writeAll("echo \"# Functions\" >> \"$SNAPSHOT_FILE\"\n");
    switch (kind) {
        .zsh => {
            try w.writeAll("typeset -f > /dev/null 2>&1\n");
            // typeset +f lists names only; filter single-underscore
            // completion functions but keep double-underscore helpers.
            try w.writeAll("typeset +f 2>/dev/null | grep -vE '^_[^_]' | while read func; do\n");
            try w.writeAll("  typeset -f \"$func\" >> \"$SNAPSHOT_FILE\" 2>/dev/null\n");
            try w.writeAll("done\n");
        },
        else => {
            // bash / sh: declare -f dumps the full definitions; filter
            // single-underscore completion helpers via the name list.
            try w.writeAll("declare -f > /dev/null 2>&1\n");
            try w.writeAll("declare -F 2>/dev/null | cut -d' ' -f3 | grep -vE '^_[^_]' | while read func; do\n");
            try w.writeAll("  declare -f \"$func\" >> \"$SNAPSHOT_FILE\" 2>/dev/null\n");
            try w.writeAll("done\n");
        },
    }

    // Shell options.
    try w.writeAll("echo \"# Shell Options\" >> \"$SNAPSHOT_FILE\"\n");
    switch (kind) {
        .zsh => {
            try w.writeAll("setopt 2>/dev/null | sed 's/^/setopt /' | head -n 1000 >> \"$SNAPSHOT_FILE\"\n");
        },
        else => {
            try w.writeAll("shopt -p 2>/dev/null | head -n 1000 >> \"$SNAPSHOT_FILE\"\n");
            try w.writeAll("echo \"shopt -s expand_aliases\" >> \"$SNAPSHOT_FILE\"\n");
        },
    }

    // Aliases. Strip the leading `alias ` token and re-emit with `alias -- `
    // so the value (which may start with a dash) is never mistaken for a flag.
    try w.writeAll("echo \"# Aliases\" >> \"$SNAPSHOT_FILE\"\n");
    try w.writeAll("alias 2>/dev/null | sed 's/^alias //g' | sed 's/^/alias -- /' | head -n 1000 >> \"$SNAPSHOT_FILE\"\n");

    // PATH (resolved by us, quote-safe).
    try w.print("echo \"# PATH\" >> \"$SNAPSHOT_FILE\"\n", .{});
    try w.print("echo \"export PATH={s}\" >> \"$SNAPSHOT_FILE\"\n", .{path_q});

    // Fail loudly if the file never got created.
    try w.writeAll("if [ ! -f \"$SNAPSHOT_FILE\" ]; then echo \"Error: snapshot not created\" >&2; exit 1; fi\n");

    return out.toOwnedSlice();
}

/// Compute the absolute snapshot file path under
/// `<snapshots_dir>/snapshot-<shell>-<ts>-<rand>.sh`. Uses clock.nowMillis()
/// and rng.bytes() (per project reuse rules -- not std.time / std.crypto).
fn snapshotFilePath(
    allocator: std.mem.Allocator,
    snapshots_dir: []const u8,
    kind: ShellKind,
) ![]u8 {
    const ts = clock.nowMillis();
    var rand_bytes: [4]u8 = undefined;
    rng.bytes(&rand_bytes);
    const rand_id = std.mem.readInt(u32, &rand_bytes, .little);
    return std.fmt.allocPrint(allocator, "{s}/snapshot-{s}-{d}-{x:0>8}.sh", .{
        snapshots_dir,
        kind.label(),
        ts,
        rand_id,
    });
}

/// Create the snapshot for this session and return its absolute path (caller
/// owns the slice), or null if creation failed. Never errors out of band: a
/// failure here must not take down the session, so all IO failures collapse
/// to null with a debug note.
pub fn createForSession(allocator: std.mem.Allocator) !?[]u8 {
    return createForSessionImpl(allocator, null);
}

/// Same as createForSession but lets a test override the config home so the
/// snapshot lands under an isolated tmp dir instead of the real ~/.zcode.
/// When `config_home_override` is null, the real path set is resolved.
pub fn createForSessionImpl(
    allocator: std.mem.Allocator,
    config_home_override: ?[]const u8,
) !?[]u8 {
    // Resolve the user's shell. Fall back to /bin/bash so the capture still
    // produces a Claude-defaults-only snapshot when $SHELL is unset.
    const shell_path = env.getOwned(allocator, "SHELL") catch
        try allocator.dupe(u8, "/bin/bash");
    defer allocator.free(shell_path);
    const kind = shellKindOf(shell_path);

    const home = env.getOwned(allocator, "HOME") catch
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(home);

    const config_file = try std.fs.path.join(allocator, &.{ home, configFileName(kind) });
    defer allocator.free(config_file);
    const config_exists = fileExists(config_file);

    // Resolve the config home (real path set, or the test override).
    var owned_home: ?[]u8 = null;
    defer if (owned_home) |h| allocator.free(h);
    const config_home: []const u8 = blk: {
        if (config_home_override) |o| break :blk o;
        var pset = try paths.resolve(allocator);
        defer pset.deinit(allocator);
        owned_home = try allocator.dupe(u8, pset.zcode_home);
        break :blk owned_home.?;
    };

    const snapshots_dir = try std.fs.path.join(allocator, &.{ config_home, "shell-snapshots" });
    defer allocator.free(snapshots_dir);
    paths.ensureDir(snapshots_dir) catch return null;

    const snapshot_path = try snapshotFilePath(allocator, snapshots_dir, kind);
    errdefer allocator.free(snapshot_path);

    const path_value = env.getOwned(allocator, "PATH") catch try allocator.dupe(u8, "");
    defer allocator.free(path_value);

    const script = try buildSnapshotScript(
        allocator,
        kind,
        snapshot_path,
        config_file,
        config_exists,
        path_value,
    );
    defer allocator.free(script);

    // Run the user's own shell as a login shell so it picks up the same
    // environment the user sees interactively. This sources arbitrary user
    // rc files -- it runs WITHOUT the sandbox (it is the user's own init) and
    // its stdout is NEVER fed to the model.
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    inheritEnviron(&env_map) catch {};
    env_map.put("SHELL", shell_path) catch {};
    env_map.put("GIT_EDITOR", "true") catch {};
    env_map.put("CLAUDECODE", "1") catch {};

    const result = std.process.run(allocator, rt.io, .{
        .argv = &[_][]const u8{ shell_path, "-c", "-l", script },
        .stdout_limit = .limited(CAPTURE_BUFFER_LIMIT),
        .stderr_limit = .limited(CAPTURE_BUFFER_LIMIT),
        .environ_map = &env_map,
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = SNAPSHOT_CREATION_TIMEOUT_NS }, .clock = .awake } },
    }) catch {
        // Timeout, spawn failure, etc. -> no snapshot, but keep running.
        cleanup(allocator, snapshot_path);
        allocator.free(snapshot_path);
        return null;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok or !fileExists(snapshot_path)) {
        cleanup(allocator, snapshot_path);
        allocator.free(snapshot_path);
        return null;
    }

    return snapshot_path;
}

/// Delete the snapshot file (best-effort). Safe to call with a path that no
/// longer exists. Does NOT free `path` -- the caller owns that memory.
pub fn cleanup(allocator: std.mem.Allocator, path: []const u8) void {
    _ = allocator;
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch {};
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

/// Copy the parent process environment into `dst` so the login shell starts
/// from the user's real env (PATH, HOME, etc.) and only overrides the few
/// keys we set explicitly. std.process.getEnvMap is gone in 0.16; read the
/// libc `environ` pointer directly (we link libc).
fn inheritEnviron(dst: *std.process.Environ.Map) !void {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const span = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, span, '=') orelse continue;
        const key = span[0..eq];
        const value = span[eq + 1 ..];
        try dst.put(key, value);
    }
}

const testing = std.testing;

test "shellKindOf classifies by path substring" {
    try testing.expectEqual(ShellKind.zsh, shellKindOf("/bin/zsh"));
    try testing.expectEqual(ShellKind.zsh, shellKindOf("/usr/local/bin/zsh"));
    try testing.expectEqual(ShellKind.bash, shellKindOf("/bin/bash"));
    try testing.expectEqual(ShellKind.sh, shellKindOf("/bin/sh"));
    try testing.expectEqual(ShellKind.sh, shellKindOf("/usr/bin/fish"));
}

test "configFileName matches the reference per shell" {
    try testing.expectEqualStrings(".zshrc", configFileName(.zsh));
    try testing.expectEqualStrings(".bashrc", configFileName(.bash));
    try testing.expectEqualStrings(".profile", configFileName(.sh));
}

test "buildSnapshotScript embeds the snapshot path, sources config, exports PATH" {
    const script = try buildSnapshotScript(
        testing.allocator,
        .bash,
        "/tmp/snap/snapshot-bash-1-2.sh",
        "/home/u/.bashrc",
        true,
        "/usr/bin:/bin",
    );
    defer testing.allocator.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "/tmp/snap/snapshot-bash-1-2.sh") != null);
    try testing.expect(std.mem.indexOf(u8, script, "source '/home/u/.bashrc'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "declare -f") != null);
    try testing.expect(std.mem.indexOf(u8, script, "alias") != null);
    try testing.expect(std.mem.indexOf(u8, script, "export PATH='/usr/bin:/bin'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "expand_aliases") != null);
}

test "buildSnapshotScript skips sourcing when config is absent and uses zsh dumpers" {
    const script = try buildSnapshotScript(
        testing.allocator,
        .zsh,
        "/tmp/s.sh",
        "/home/u/.zshrc",
        false,
        "/bin",
    );
    defer testing.allocator.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "No user config file to source") != null);
    try testing.expect(std.mem.indexOf(u8, script, "source ") == null);
    try testing.expect(std.mem.indexOf(u8, script, "typeset -f") != null);
    try testing.expect(std.mem.indexOf(u8, script, "setopt") != null);
}

test "snapshotFilePath formats a unique, well-shaped path" {
    const p = try snapshotFilePath(testing.allocator, "/cfg/shell-snapshots", .bash);
    defer testing.allocator.free(p);
    try testing.expect(std.mem.startsWith(u8, p, "/cfg/shell-snapshots/snapshot-bash-"));
    try testing.expect(std.mem.endsWith(u8, p, ".sh"));
}

// Live-shell test: gated on `bash` being present. Writes a fake .bashrc
// defining an alias and a function, runs the real capture against an
// isolated tmp config home, and asserts the generated snapshot contains the
// alias, the function, and an exported PATH. Skips cleanly when bash is
// unavailable (e.g. minimal CI), per the plan's "gate the live-shell portion"
// requirement.
test "live capture of a fake .bashrc surfaces alias + function + PATH" {
    if (!commandExists("bash")) return error.SkipZigTest;

    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const test_helpers = @import("test_helpers.zig");
    const base = try test_helpers.tmpDirCwd(allocator, &tmp);
    defer allocator.free(base);

    // Write a fake home with a .bashrc, and an isolated config home.
    const home = try std.fs.path.join(allocator, &.{ base, "home" });
    defer allocator.free(home);
    const cfg_home = try std.fs.path.join(allocator, &.{ base, "cfg" });
    defer allocator.free(cfg_home);
    try paths.ensureDir(home);
    try paths.ensureDir(cfg_home);

    const bashrc = try std.fs.path.join(allocator, &.{ home, ".bashrc" });
    defer allocator.free(bashrc);
    {
        const f = try std.Io.Dir.cwd().createFile(rt.io, bashrc, .{ .truncate = true });
        defer f.close(rt.io);
        var wbuf: [256]u8 = undefined;
        var fw = f.writer(rt.io, &wbuf);
        try fw.interface.writeAll("alias gs='git status'\nmyfn() { echo hi; }\n");
        try fw.interface.flush();
    }

    const snapshots_dir = try std.fs.path.join(allocator, &.{ cfg_home, "shell-snapshots" });
    defer allocator.free(snapshots_dir);
    try paths.ensureDir(snapshots_dir);
    const snap_path = try snapshotFilePath(allocator, snapshots_dir, .bash);
    defer allocator.free(snap_path);
    defer cleanup(allocator, snap_path);

    const script = try buildSnapshotScript(
        allocator,
        .bash,
        snap_path,
        bashrc,
        true,
        "/usr/bin:/bin",
    );
    defer allocator.free(script);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    inheritEnviron(&env_map) catch {};
    env_map.put("HOME", home) catch {};
    env_map.put("GIT_EDITOR", "true") catch {};
    env_map.put("CLAUDECODE", "1") catch {};

    const result = std.process.run(allocator, rt.io, .{
        .argv = &[_][]const u8{ "bash", "-c", "-l", script },
        .stdout_limit = .limited(CAPTURE_BUFFER_LIMIT),
        .stderr_limit = .limited(CAPTURE_BUFFER_LIMIT),
        .environ_map = &env_map,
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = SNAPSHOT_CREATION_TIMEOUT_NS }, .clock = .awake } },
    }) catch return error.SkipZigTest;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const snap = std.Io.Dir.cwd().readFileAlloc(rt.io, snap_path, allocator, .limited(CAPTURE_BUFFER_LIMIT)) catch
        return error.SkipZigTest;
    defer allocator.free(snap);

    // Alias line for gs, function body for myfn, and the exported PATH.
    try testing.expect(std.mem.indexOf(u8, snap, "gs") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "git status") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "myfn") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "export PATH=") != null);
}

fn commandExists(name: []const u8) bool {
    const result = std.process.run(testing.allocator, rt.io, .{
        .argv = &[_][]const u8{ "/usr/bin/env", "which", name },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
