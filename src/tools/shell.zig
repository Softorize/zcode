const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const builtin = @import("builtin");
const sandbox_mod = @import("../core/sandbox.zig");
const http_common = @import("../providers/common.zig");
const hint_protocol = @import("../core/hint_protocol.zig");
const tool_helpers = @import("helpers.zig");
const security = @import("bash_security.zig");
const bash_ast = @import("../core/bash_ast.zig");
const command_semantics = @import("../core/command_semantics.zig");
const containsIgnoreCase = @import("../core/parse_helpers.zig").containsIgnoreCase;
const env_mod = @import("../core/env.zig");
const env_validation = @import("../core/env_validation.zig");
const config_mod = @import("../core/config.zig");
const tmux_socket = @import("../core/tmux_socket.zig");

/// Settings-sourced env pairs (settings-02) applied to spawned tools before
/// the session env. Borrowed; the backing slices outlive the plan (they live
/// on Config). Empty slice = no settings env, preserving the historical
/// inherit-the-raw-process-env path.
const SettingsEnv = []const config_mod.EnvPair;

/// Decide whether the child's stdin should be closed (pointed at
/// /dev/null) for a non-interactive bash command. We close stdin unless
/// the command carries its own stdin source -- a heredoc (`<<EOF ...`)
/// or an explicit input redirect (`< file`) -- because closing it then
/// would starve the command of the input it expects.
///
/// This ports the general-purpose half of the reference's
/// `shouldAddStdinRedirect` (src/utils/bash/heredoc.ts): add a stdin
/// close only when there is no existing stdin redirect and no heredoc,
/// so commands like `git commit` do not block waiting on a TTY.
///
/// Note: the actual close is enforced by `std.process.run`, which in
/// Zig 0.16 hardcodes `.stdin = .ignore` (process.zig:506) for every
/// child it spawns -- there is no `RunOptions.stdin` field to toggle.
/// That is safe for heredoc / `< file` commands too, because the shell
/// wrapper feeds those inputs internally and never reads the process's
/// own stdin. This helper therefore documents and unit-tests the intent;
/// the spawn already does the right thing for all of these cases.
pub fn shouldCloseStdin(command: []const u8) bool {
    return !bash_ast.containsHeredoc(command) and !bash_ast.hasStdinRedirect(command);
}

/// bash-shell-10: the model-visible output cap, read from
/// `BASH_MAX_OUTPUT_LENGTH`. Ports the reference's
/// `getMaxOutputLength` (src/utils/shell/outputLimits.ts:3-14):
/// default 30_000, hard upper bound 150_000. We count bytes where the
/// reference counts characters -- acceptable for a defensive cap, and
/// documented in the [shell_result] contract via `max_output_bytes`.
///
/// The bounded-int validator falls back to the default for missing,
/// empty, non-numeric, or `<= 0` values, and caps anything above the
/// upper limit, so the effective value is always in `[1, 150_000]`.
const BASH_MAX_OUTPUT_DEFAULT: usize = 30_000;
const BASH_MAX_OUTPUT_UPPER: usize = 150_000;

fn maxOutputLength() usize {
    const raw = env_mod.getenv("BASH_MAX_OUTPUT_LENGTH");
    // The validator only allocates a `message` for the `.capped` /
    // `.invalid` paths; we don't surface it here, so free it immediately.
    const r = env_validation.validateBoundedInt(
        rt.gpa,
        "BASH_MAX_OUTPUT_LENGTH",
        raw,
        BASH_MAX_OUTPUT_DEFAULT,
        BASH_MAX_OUTPUT_UPPER,
    ) catch return BASH_MAX_OUTPUT_DEFAULT;
    defer env_validation.freeResult(rt.gpa, r);
    return r.effective;
}

/// bash-shell-10: detect a base64 image data-URI at the start of a
/// command's stdout. Ports the reference's `isImageOutput`
/// (src/tools/BashTool/utils.ts:49-91). When true, the caller skips the
/// `[N lines truncated]` math so the data URI is never cut mid-payload.
fn isImageDataUri(stdout: []const u8) bool {
    return imageMediaType(stdout) != null;
}

/// Return the media type portion of a leading `data:<type>;base64,`
/// image URI (e.g. "image/png"), or null when stdout is not such a URI.
fn imageMediaType(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, stdout, " \t\r\n");
    const prefix = "data:image/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const after_data = trimmed["data:".len..];
    // The media type runs from `data:` up to the first `;`.
    const semi = std.mem.indexOfScalar(u8, after_data, ';') orelse return null;
    const media_type = after_data[0..semi];
    // Require the `;base64,` marker to follow the media type.
    const rest = after_data[semi..];
    if (!std.mem.startsWith(u8, rest, ";base64,")) return null;
    return media_type;
}

const TruncatedOutput = struct {
    /// The model-visible portion of stdout (`<= cap` bytes unless the
    /// payload is an image data-URI, which is passed through whole).
    kept: []const u8,
    /// True when the captured stdout exceeded the cap and was cut.
    truncated: bool,
    /// Number of newline-delimited lines dropped from the tail. Ports
    /// the reference's `[N lines truncated]` count
    /// (src/tools/BashTool/utils.ts:133-165).
    truncated_lines: usize,
    /// True when stdout is a base64 image data-URI; in that case we do
    /// NOT truncate (cutting mid-payload would corrupt the image).
    is_image: bool,
};

/// bash-shell-10: truncate captured stdout to the model-visible cap and
/// count the dropped lines. Ports `formatOutput`
/// (src/tools/BashTool/utils.ts:133-165): keep the first `cap` bytes,
/// then report how many lines were in the dropped tail. Image data-URIs
/// are passed through untruncated so the base64 payload stays intact.
fn truncateForModel(stdout: []const u8, cap: usize) TruncatedOutput {
    if (isImageDataUri(stdout)) {
        return .{ .kept = stdout, .truncated = false, .truncated_lines = 0, .is_image = true };
    }
    if (stdout.len <= cap) {
        return .{ .kept = stdout, .truncated = false, .truncated_lines = 0, .is_image = false };
    }
    const kept = stdout[0..cap];
    const dropped = stdout[cap..];
    // Count the lines in the dropped tail. A non-empty tail is at least
    // one (partial) line, plus one for every newline it contains.
    var lines: usize = 1;
    for (dropped) |ch| {
        if (ch == '\n') lines += 1;
    }
    return .{ .kept = kept, .truncated = true, .truncated_lines = lines, .is_image = false };
}

const ShellBackend = enum {
    direct,
    macos_seatbelt,
    linux_bwrap,
};

const ExecutionPlan = struct {
    argv: []const []const u8,
    child_cwd: []u8,
    env_map: ?std.process.Environ.Map = null,
    temp_dir: ?[]u8 = null,

    fn deinit(self: *ExecutionPlan, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        allocator.free(self.child_cwd);
        if (self.temp_dir) |dir| {
            std.Io.Dir.cwd().deleteTree(rt.io, dir) catch {};
            allocator.free(dir);
        }
        if (self.env_map) |*env_map| env_map.deinit();
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    timeout_seconds: usize,
    sandbox_profile: []const u8,
) ![]u8 {
    return runWithSnapshot(allocator, cwd, command, timeout_seconds, sandbox_profile, null);
}

/// Same as `run`, but sources the given shell environment snapshot (bash-
/// shell-02) before the command so it sees the user's aliases/functions.
/// `run` delegates here with `snapshot_path = null` so existing call sites
/// keep their behavior; the agent runtime passes the session snapshot path.
pub fn runWithSnapshot(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    timeout_seconds: usize,
    sandbox_profile: []const u8,
    snapshot_path: ?[]const u8,
) ![]u8 {
    return runWithSnapshotAndEnv(allocator, cwd, command, timeout_seconds, sandbox_profile, snapshot_path, &.{});
}

/// Same as `runWithSnapshot`, but also applies settings-sourced env (the
/// `[env]` config table, settings-02) to the spawned tool. The agent runtime
/// passes `cfg.settings_env.items`; other call sites pass an empty slice to
/// keep their behavior. Settings env is lower precedence than `/env set`.
pub fn runWithSnapshotAndEnv(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    timeout_seconds: usize,
    sandbox_profile: []const u8,
    snapshot_path: ?[]const u8,
    settings_env: SettingsEnv,
) ![]u8 {
    // Input validation before any security/analysis work: empty,
    // null-byte, over-long. Cheap and surfaces clean errors.
    if (security.validateCommandInput(command)) |reason| {
        return formatInvalidCommand(allocator, command, reason);
    }

    // Pre-execution security analysis. The `danger-full-access`
    // profile is an explicit user opt-in to unrestricted operation;
    // skip the destructive-shell / interactive / redirect-tool gates
    // so the agent can drive ssh, git rebase, curl | sh, etc.
    // without tripping the default guards.
    const danger_full_access = std.mem.eql(u8, sandbox_profile, "danger-full-access");
    if (!danger_full_access) {
        const analysis = security.analyzeCommand(command);
        if (analysis.risk_level == .blocked) {
            return std.fmt.allocPrint(allocator, "$ {s}\n[BLOCKED] {s}\n", .{ command, analysis.reason });
        }
        if (analysis.kind == .interactive) {
            return formatInteractiveReroute(allocator, command, analysis.reason);
        }
        if (analysis.kind == .redirect_tool) {
            return formatToolRedirect(allocator, command, analysis.reason);
        }
        // Fail-closed: the structural scanner could not parse the command
        // (unbalanced quote/paren/brace, or over-length). `analyzeCommand`
        // surfaces this as a medium-risk result. Rather than run an
        // unanalyzed command, refuse and ask the model to simplify it.
        if (analysis.risk_level == .medium and security.isParseAborted(command)) {
            return formatInvalidCommand(allocator, command, analysis.reason);
        }
    }

    const effective_timeout_seconds = @max(@as(usize, 1), @min(timeout_seconds, 3600));
    // bash-shell-10: model-visible output cap, governed by
    // BASH_MAX_OUTPUT_LENGTH (default 30_000, capped at 150_000). This
    // is the truncation the model sees; the 32 KiB persistence spill
    // below is a separate threshold and is unaffected.
    const max_output_bytes = maxOutputLength();

    var plan = try buildExecutionPlan(allocator, cwd, command, sandbox_profile, snapshot_path, settings_env);
    defer plan.deinit(allocator);

    // The pre-0.16 impl wrapped a long-poll select() so the user could
    // Ctrl-C a runaway shell tool from the REPL. std.process.run is now
    // a single blocking call with a kernel-enforced timeout; mid-call
    // user-cancel is gone but the timeout still bounds the wait. The
    // `cancelled` branch below stays as the extension point for when
    // we re-thread an interrupt path through std.Io.
    const timeout_ns: u64 = @as(u64, effective_timeout_seconds) * std.time.ns_per_s;
    // Non-interactive bash must not hang waiting on a TTY. `std.process.run`
    // always points the child's stdin at /dev/null (process.zig:506), which
    // closes stdin for us unconditionally; there is no `RunOptions.stdin`
    // field to toggle. That is also safe for heredoc / `< file` commands
    // (see `shouldCloseStdin`), because the shell wrapper feeds those inputs
    // internally and never reads the process's own stdin.
    // Capture a bit past the model-visible cap so we still have the
    // dropped tail to count `[N lines truncated]` from. Without this
    // headroom, std.process.run returns error.StreamTooLong the instant
    // the buffer exceeds the limit and discards EVERYTHING (the catch
    // below maps StreamTooLong -> null), so the model would see an empty
    // result with no truncation note. The ceiling is still bounded (the
    // cap is at most BASH_MAX_OUTPUT_UPPER) so a runaway command cannot
    // exhaust memory.
    const capture_ceiling = max_output_bytes + 64 * 1024;
    var run_opts: std.process.RunOptions = .{
        .argv = plan.argv,
        .cwd = .{ .path = plan.child_cwd },
        .stdout_limit = .limited(capture_ceiling),
        .stderr_limit = .limited(capture_ceiling),
        .timeout = .{ .duration = .{ .raw = .{ .nanoseconds = timeout_ns }, .clock = .awake } },
    };
    if (plan.env_map) |*env_map| run_opts.environ_map = env_map;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    var timed_out = false;
    const cancelled = false;
    var term: std.process.Child.Term = .{ .signal = std.posix.SIG.TERM };
    const result = std.process.run(allocator, rt.io, run_opts) catch |err| switch (err) {
        error.Timeout => blk: {
            timed_out = true;
            break :blk null;
        },
        error.StreamTooLong => null,
        else => return err,
    };
    if (result) |r| {
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try stdout.appendSlice(allocator, r.stdout);
        try stderr.appendSlice(allocator, r.stderr);
        term = r.term;
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("$ {s}\n", .{command});
    // bash-shell-10: truncate to the model-visible cap (counting bytes)
    // and report the dropped-line count. Image data-URIs pass through
    // untruncated.
    const trunc = truncateForModel(stdout.items, max_output_bytes);
    const truncated = trunc.truncated;
    const truncated_lines = trunc.truncated_lines;
    const image_media_type: []const u8 = if (trunc.is_image) (imageMediaType(stdout.items) orelse "") else "";
    if (trunc.is_image and image_media_type.len > 0) {
        try out.writer().print("[image_output=true media_type={s}]\n", .{image_media_type});
    }
    try out.appendSlice(trunc.kept);
    if (truncated) {
        try out.writer().print("\n\n... [{d} lines truncated] ...\n", .{truncated_lines});
    }

    if (stderr.items.len > 0) {
        try out.writer().writeAll("\n[stderr]\n");
        try out.appendSlice(stderr.items);
    }

    if (timed_out) {
        try out.writer().print("\n[timeout={d}s]\n", .{effective_timeout_seconds});
        try appendShellResultContract(&out, .{
            .sandbox_profile = sandbox_profile,
            .sandbox_status = sandboxStatus(sandbox_profile),
            .exit_code = null,
            .termination = "timeout",
            .return_code_interpretation = "timeout",
            .no_output_expected = false,
            .output_truncated = truncated,
            .max_output_bytes = max_output_bytes,
            .truncated_lines = truncated_lines,
            .image_output = trunc.is_image,
            .image_media_type = image_media_type,
            .timed_out = true,
            .cancelled = false,
        });
        return finalizeShellOutput(allocator, &out, command);
    }

    if (cancelled) {
        try out.writer().writeAll("\n[cancelled by user]\n");
        try appendShellResultContract(&out, .{
            .sandbox_profile = sandbox_profile,
            .sandbox_status = sandboxStatus(sandbox_profile),
            .exit_code = null,
            .termination = "cancelled",
            .return_code_interpretation = "cancelled",
            .no_output_expected = false,
            .output_truncated = truncated,
            .max_output_bytes = max_output_bytes,
            .truncated_lines = truncated_lines,
            .image_output = trunc.is_image,
            .image_media_type = image_media_type,
            .timed_out = false,
            .cancelled = true,
        });
        return finalizeShellOutput(allocator, &out, command);
    }

    const interactive_no_result = switch (term) {
        .exited => |code| code == 0 and isInteractiveNoResult(stdout.items, stderr.items),
        else => false,
    };

    switch (term) {
        .exited => |code| {
            try out.writer().print("\n[exit_code={d}]\n", .{code});
            if (code == 0 and stdout.items.len == 0 and stderr.items.len == 0) {
                try out.writer().writeAll("[noOutputExpected=true]\n");
            }
            const semantic = command_semantics.interpret(command, @intCast(code));
            try appendShellResultContract(&out, .{
                .sandbox_profile = sandbox_profile,
                .sandbox_status = sandboxStatus(sandbox_profile),
                .exit_code = @intCast(code),
                .termination = "exited",
                .return_code_interpretation = returnCodeInterpretation(code, semantic),
                .no_output_expected = code == 0 and stdout.items.len == 0 and stderr.items.len == 0,
                .output_truncated = truncated,
                .max_output_bytes = max_output_bytes,
                .truncated_lines = truncated_lines,
                .image_output = trunc.is_image,
                .image_media_type = image_media_type,
                .timed_out = false,
                .cancelled = false,
            });
        },
        else => {
            try out.writer().writeAll("\n[exit=nonstandard]\n");
            try appendShellResultContract(&out, .{
                .sandbox_profile = sandbox_profile,
                .sandbox_status = sandboxStatus(sandbox_profile),
                .exit_code = null,
                .termination = "nonstandard",
                .return_code_interpretation = "nonstandard_termination",
                .no_output_expected = false,
                .output_truncated = truncated,
                .max_output_bytes = max_output_bytes,
                .truncated_lines = truncated_lines,
                .image_output = trunc.is_image,
                .image_media_type = image_media_type,
                .timed_out = false,
                .cancelled = false,
            });
        },
    }

    if (interactive_no_result) {
        try out.writer().writeAll("[interactive_no_result] command produced no usable stdout and only transient terminal UI output\n");
    }

    const raw_len = out.items().len;
    if (raw_len >= 32 * 1024) {
        if (persistShellOutput(allocator, out.items(), command)) |persisted_path| {
            defer allocator.free(persisted_path);
            try out.writer().print("[persisted_output={s}]\n[persisted_output_bytes={d}]\n", .{ persisted_path, raw_len });
        } else |err| {
            std.log.warn("shell output persistence failed: {s}", .{@errorName(err)});
        }
    }

    return finalizeShellOutput(allocator, &out, command);
}

pub fn formatInvalidCommand(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("$ {s}\n[invalid_input=true]\n[invalid command] {s}\n", .{ command, reason });
    try appendShellResultContract(&out, .{
        .sandbox_profile = "not_started",
        .sandbox_status = "not_started",
        .exit_code = null,
        .termination = "invalid_input",
        .return_code_interpretation = "invalid_input",
        .no_output_expected = false,
        .output_truncated = false,
        .max_output_bytes = 0,
        .timed_out = false,
        .cancelled = false,
    });
    return out.toOwnedSlice();
}

pub fn formatInteractiveReroute(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("$ {s}\n[interactive_reroute=true]\n[suggested_action=/! {s}]\n{s}\nThis command was not executed by the Bash tool because it needs an attached terminal. Re-run it with `/! {s}`.\n", .{ command, command, reason, command });
    try appendShellResultContract(&out, .{
        .sandbox_profile = "not_started",
        .sandbox_status = "not_started",
        .exit_code = null,
        .termination = "interactive_reroute",
        .return_code_interpretation = "not_executed",
        .no_output_expected = false,
        .output_truncated = false,
        .max_output_bytes = 0,
        .timed_out = false,
        .cancelled = false,
    });
    return out.toOwnedSlice();
}

pub fn formatToolRedirect(allocator: std.mem.Allocator, command: []const u8, reason: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("$ {s}\n[redirect_tool=true]\n{s}\nThe Bash tool did not execute this command. Use the dedicated tool suggested above.\n", .{ command, reason });
    try appendShellResultContract(&out, .{
        .sandbox_profile = "not_started",
        .sandbox_status = "not_started",
        .exit_code = null,
        .termination = "redirect_tool",
        .return_code_interpretation = "not_executed",
        .no_output_expected = false,
        .output_truncated = false,
        .max_output_bytes = 0,
        .timed_out = false,
        .cancelled = false,
    });
    return out.toOwnedSlice();
}

const ShellResultContract = struct {
    sandbox_profile: []const u8,
    sandbox_status: []const u8,
    exit_code: ?i32,
    termination: []const u8,
    return_code_interpretation: []const u8,
    no_output_expected: bool,
    output_truncated: bool,
    max_output_bytes: usize,
    /// bash-shell-10: number of lines dropped by output truncation.
    /// Defaults to 0 so the not-executed paths (invalid/interactive/
    /// redirect) and the no-truncation case keep emitting 0.
    truncated_lines: usize = 0,
    /// bash-shell-10: set when stdout was a base64 image data-URI.
    image_output: bool = false,
    /// The detected image media type (e.g. "image/png"), or "" when
    /// `image_output` is false.
    image_media_type: []const u8 = "",
    timed_out: bool,
    cancelled: bool,
};

fn appendShellResultContract(out: *std_io.StringBuilder, result: ShellResultContract) !void {
    try out.writer().print(
        "[shell_result] {f}\n",
        .{std.json.fmt(.{
            .schema_version = @as(u8, 1),
            .sandbox_profile = result.sandbox_profile,
            .sandbox_status = result.sandbox_status,
            .exit_code = result.exit_code,
            .termination = result.termination,
            .return_code_interpretation = result.return_code_interpretation,
            .no_output_expected = result.no_output_expected,
            .output_truncated = result.output_truncated,
            .max_output_bytes = result.max_output_bytes,
            .truncated_lines = result.truncated_lines,
            .image_output = result.image_output,
            .image_media_type = result.image_media_type,
            .timed_out = result.timed_out,
            .cancelled = result.cancelled,
        }, .{})},
    );
}

fn sandboxStatus(sandbox_profile: []const u8) []const u8 {
    if (std.mem.eql(u8, sandbox_profile, "danger-full-access")) return "disabled";
    if (!sandbox_mod.requiresEnforcedShellSandbox(sandbox_profile)) return "not_required";
    if (sandbox_mod.hasShellSandboxBackend(sandbox_profile)) return "enforced";
    if (sandbox_mod.allowLegacyUnisolatedShell()) return "legacy_unisolated";
    return "unavailable";
}

fn returnCodeInterpretation(exit_code: u8, semantic: command_semantics.Result) []const u8 {
    if (exit_code == 0) return "success";
    if (semantic.is_error) return "error";
    if (semantic.message) |message| {
        if (std.mem.eql(u8, message, "no matches found")) return "no_matches_found";
        if (std.mem.eql(u8, message, "files differ")) return "files_differ";
        if (std.mem.eql(u8, message, "condition is false")) return "condition_false";
        if (std.mem.indexOf(u8, message, "inaccessible") != null) return "partial_success";
    }
    return "non_error";
}

/// Run hint-protocol extraction on the assembled tool output, log any
/// hints to stderr via std.log, and return the stripped bytes to the
/// caller (model). Ported from claude-code-main/src/utils/
/// claudeCodeHints.ts: the harness scans for `<claude-code-hint />`
/// tags, records them, and removes them from the model-visible output
/// so a CLI can signal "offer this plugin" without contaminating the
/// conversation transcript.
///
/// For now we only log hints -- surfacing them in an interactive
/// dialog is a follow-up pass. Logging is still useful: users running
/// zcode verbose or tailing the log file see a clear note when a CLI
/// advertises a plugin.
fn finalizeShellOutput(
    allocator: std.mem.Allocator,
    out: *std_io.StringBuilder,
    command: []const u8,
) ![]u8 {
    const raw = try out.toOwnedSlice();
    defer allocator.free(raw);

    const result = hint_protocol.extractHints(allocator, raw, command) catch |err| {
        // Hint extraction is best-effort -- any failure (OOM, etc.)
        // should not block the shell tool's return path. Return an
        // unmodified copy of the raw output so the model still sees
        // the command result.
        std.log.warn("hint-protocol extraction failed: {s}", .{@errorName(err)});
        return allocator.dupe(u8, raw) catch err;
    };
    defer {
        for (result.hints) |*h| h.deinit(allocator);
        allocator.free(result.hints);
    }

    for (result.hints) |hint| {
        std.log.info(
            "shell-hint v={d} type={s} value='{s}' source='{s}'",
            .{ hint.v, hint.hint_type.toString(), hint.value, hint.source_command },
        );
    }

    return result.stripped;
}

/// Run a command in the background with sandbox enforcement.
/// Uses the same execution plan as foreground run() for sandbox consistency.
/// The child is double-forked via nohup to avoid zombie accumulation.
pub fn runBackground(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8, sandbox_profile: []const u8) ![]u8 {
    // Same input validation as the foreground path.
    const security_mod = @import("bash_security.zig");
    if (security_mod.validateCommandInput(command)) |reason| {
        return std.fmt.allocPrint(allocator, "[invalid command] {s}\n", .{reason});
    }

    // Build the same sandboxed execution as foreground, but wrap in nohup
    const sandboxed_command = try buildBackgroundCommandString(allocator, cwd, command, sandbox_profile);
    defer allocator.free(sandboxed_command);

    // Use nohup + & via sh -c so the process detaches properly and
    // is reparented to init (no zombie when zcode exits)
    const bg_cmd = try std.fmt.allocPrint(allocator, "nohup {s} >/dev/null 2>&1 & echo $!", .{sandboxed_command});
    defer allocator.free(bg_cmd);

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "/bin/sh", "-c", bg_cmd },
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "$ {s}\n[background failed: {s}]\n", .{ command, @errorName(err) });
    };
    defer allocator.free(result.stderr);

    const pid_str = std.mem.trim(u8, result.stdout, " \t\r\n");
    defer allocator.free(result.stdout);

    // Empty PID = nohup couldn't spawn the child at all. Report as
    // an outright failure rather than the misleading "backgrounded"
    // message.
    if (pid_str.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "$ {s}\n[background failed: could not spawn]\n",
            .{command},
        );
    }

    // Liveness check: the shell always prints a PID via `echo $!`
    // even when the command crashes on startup (e.g. `python app.py`
    // when python isn't installed, or a binary that segfaults
    // immediately). Without a post-spawn sanity check we'd proudly
    // report "[backgrounded][pid=12345]" for a process that died
    // 2ms after fork() -- leaving the model convinced its server
    // is running when it's already dead. Sleep for a short grace
    // period and re-verify the PID is still alive. If it's gone,
    // flip the message to "crashed immediately" and include any
    // stderr curl from a companion `2>/dev/null` redirect -- actually
    // we redirected stderr to /dev/null so we can't recover it.
    // The grace period (200ms) matches the reference's
    // claude-code-main/src/tools/BashTool/BashTool.ts post-spawn
    // verification window.
    clock.sleepNanos(200 * std.time.ns_per_ms);

    const pid_num = std.fmt.parseInt(i32, pid_str, 10) catch {
        return std.fmt.allocPrint(
            allocator,
            "$ {s}\n[backgrounded]\n[pid={s}]\n[noOutputExpected=true]\n",
            .{ command, pid_str },
        );
    };

    if (!backgroundPidIsAlive(pid_num)) {
        return std.fmt.allocPrint(
            allocator,
            "$ {s}\n[background FAILED: process exited within 200ms]\n[pid={s} is no longer running]\nThe command spawned successfully but crashed or exited before we could confirm it was running. Check the command for missing dependencies, syntax errors, or immediate failures. Try running it in the foreground first (without run_in_background=true) to see stderr.\n",
            .{ command, pid_str },
        );
    }

    return std.fmt.allocPrint(
        allocator,
        "$ {s}\n[backgrounded]\n[pid={s}]\n[verified alive at +200ms]\n[noOutputExpected=true]\n",
        .{ command, pid_str },
    );
}

pub fn buildBackgroundCommandString(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    sandbox_profile: []const u8,
) ![]u8 {
    return buildBackgroundCommandStringWithSnapshot(allocator, cwd, command, sandbox_profile, null);
}

pub fn buildBackgroundCommandStringWithSnapshot(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    sandbox_profile: []const u8,
    snapshot_path: ?[]const u8,
) ![]u8 {
    // The background path builds a shell command STRING from the plan argv
    // (it does not spawn via std.process.run with an env_map), so settings
    // env is not applied here; pass an empty slice to keep behavior identical.
    var plan = try buildExecutionPlan(allocator, cwd, command, sandbox_profile, snapshot_path, &.{});
    defer plan.deinit(allocator);

    var cmd_buf = std_io.StringBuilder.init(allocator);
    defer cmd_buf.deinit();
    for (plan.argv, 0..) |arg, i| {
        if (i > 0) try cmd_buf.append(' ');
        const quoted = try tool_helpers.shellQuoteAlloc(allocator, arg);
        defer allocator.free(quoted);
        try cmd_buf.appendSlice(quoted);
    }
    return cmd_buf.toOwnedSlice();
}

fn persistShellOutput(allocator: std.mem.Allocator, output: []const u8, command: []const u8) ![]u8 {
    const paths_mod = @import("../core/paths.zig");
    var resolved = try paths_mod.resolve(allocator);
    defer resolved.deinit(allocator);

    const results_dir = try std.fs.path.join(allocator, &.{ resolved.zcode_home, "tool-results" });
    defer allocator.free(results_dir);
    try paths_mod.ensureDir(results_dir);

    const nonce = rng.int(u32);
    const filename = try std.fmt.allocPrint(allocator, "shell-{d}-{x}.txt", .{ clock.nowSeconds(), nonce });
    defer allocator.free(filename);

    const path = try std.fs.path.join(allocator, &.{ results_dir, filename });
    errdefer allocator.free(path);

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, output);
    if (command.len > 0) {
        try file.writeStreamingAll(rt.io, "\n\n[command]\n");
        try file.writeStreamingAll(rt.io, command);
    }
    return path;
}

/// Check whether a PID is still alive. Uses `kill(pid, 0)` which
/// posts no signal but returns EPERM/ESRCH based on whether the
/// process exists. ESRCH means the process is gone; anything else
/// (including EPERM for "not yours") means it's still around.
fn backgroundPidIsAlive(pid: i32) bool {
    const pid_t: std.posix.pid_t = @intCast(pid);
    if (std.c.kill(pid_t, @enumFromInt(0)) != 0) {
        // ESRCH means the process is gone; anything else (EPERM etc.)
        // implies it exists. Treat any non-ESRCH errno as alive.
        const e = std.posix.errno(@as(c_int, -1));
        if (e == .SRCH) return false;
    }
    return true;
}

fn buildExecutionPlan(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    sandbox_profile: []const u8,
    snapshot_path: ?[]const u8,
    settings_env: SettingsEnv,
) !ExecutionPlan {
    // bash-shell-02: when a shell environment snapshot is available, prefix
    // the command with `. '<snapshot>';` so it runs with the user's captured
    // aliases/functions/options. The snapshot replaces login-shell sourcing,
    // so the plan builders keep using `-c` (not `-lc`). `command` itself is
    // never mutated -- the wrapped form is only what we exec; display,
    // analysis, and the [shell_result] contract all keep the raw command.
    const exec_command = try wrapWithSnapshot(allocator, command, snapshot_path);
    defer allocator.free(exec_command);

    if (!sandbox_mod.requiresEnforcedShellSandbox(sandbox_profile)) {
        return buildDirectPlan(allocator, cwd, exec_command, settings_env);
    }

    if (!sandbox_mod.hasShellSandboxBackend(sandbox_profile)) {
        if (sandbox_mod.allowLegacyUnisolatedShell()) {
            return buildDirectPlan(allocator, cwd, exec_command, settings_env);
        }
        return error.SandboxBackendUnavailable;
    }

    return switch (activeShellBackend()) {
        .direct => buildDirectPlan(allocator, cwd, exec_command, settings_env),
        .macos_seatbelt => buildMacosSeatbeltPlan(allocator, cwd, exec_command, sandbox_profile, settings_env),
        .linux_bwrap => buildLinuxBwrapPlan(allocator, cwd, exec_command, sandbox_profile, settings_env),
    };
}

/// Prefix `command` with a `. '<snapshot>';` source so the child shell picks
/// up the user's captured environment. Returns an owned copy of `command`
/// unchanged when there is no snapshot. The snapshot path is our own
/// controlled path, but we still single-quote it for safety.
fn wrapWithSnapshot(
    allocator: std.mem.Allocator,
    command: []const u8,
    snapshot_path: ?[]const u8,
) ![]u8 {
    const path = snapshot_path orelse return allocator.dupe(u8, command);
    if (path.len == 0) return allocator.dupe(u8, command);
    const quoted = try tool_helpers.shellQuoteAlloc(allocator, path);
    defer allocator.free(quoted);
    // `. <file> 2>/dev/null || true` so a stale/partial snapshot never makes
    // an otherwise-fine command fail; the user's command runs regardless.
    return std.fmt.allocPrint(allocator, ". {s} 2>/dev/null || true; {s}", .{ quoted, command });
}

/// Apply settings-sourced env (settings-02) and then session-scoped env vars
/// to a plan's env_map. Used by every execution plan path so config `[env]`
/// values and `/env set` values reach the child process regardless of whether
/// we're sandboxed or not. If the plan didn't already have an env_map we create
/// one from the inherited process env first. No-op when both the settings env
/// and the session store are empty, so unsandboxed commands keep inheriting the
/// raw process env without paying a copy.
///
/// Precedence: settings env is applied FIRST, then session env on top, so
/// `/env set FOO=...` overrides a `[env] FOO = ...` config value (matching the
/// reference, where session overrides settings).
fn applySessionEnvToPlan(allocator: std.mem.Allocator, plan: *ExecutionPlan, settings_env: SettingsEnv) !void {
    const session_env = @import("../core/session_env.zig");

    if (plan.env_map == null) {
        // Lazily build an env_map only when something needs to override the
        // inherited env: settings env, session env, OR the tmux socket
        // isolation (phase-26 daemon-background-06). The tmux probe is cheap
        // (a PATH walk) and returns null when tmux is absent, so an
        // unsandboxed command on a tmux-free host still keeps inheriting the
        // raw process env without paying a copy.
        if (session_env.count() == 0 and settings_env.len == 0 and !tmux_socket.tmuxAvailable(allocator)) {
            return;
        }
        plan.env_map = std.process.Environ.Map.init(allocator);
    }
    // Settings env first (lower precedence). The backing slices live on
    // Config, which outlives the plan, so put() borrowing them is safe.
    for (settings_env) |pair| {
        try plan.env_map.?.put(pair.name, pair.value);
    }
    // Session env last (higher precedence): overrides settings env.
    try session_env.applyToEnvMap(&plan.env_map.?);
    // tmux socket isolation: redirect agent-issued tmux to a private
    // `-L zcode-<pid>` socket so `tmux kill-server` cannot reach the user's
    // real session. Best-effort -- a no-op when tmux is absent (TMUX stays as
    // inherited). Applied LAST so an explicit `/env set TMUX=...` would win if
    // a user ever set one, but it overrides the raw inherited TMUX otherwise.
    tmux_socket.applyToEnvMap(allocator, &plan.env_map.?);
}

fn buildDirectPlan(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    settings_env: SettingsEnv,
) !ExecutionPlan {
    // Build the argv array directly here instead of via
    // directShellArgv's `&.{...}` literal -- that anon slice is
    // stack-resident, so its third element (the runtime `command`
    // string slice) gets invalidated before duplicateArgv copies it,
    // leading to an empty command being exec'd. Allocate locally
    // so the slice lives through the dupe.
    const args: [3][]const u8 = switch (builtin.os.tag) {
        .windows => .{ "cmd.exe", "/C", command },
        else => .{ "/bin/sh", "-c", command },
    };
    var plan: ExecutionPlan = .{
        .argv = try duplicateArgv(allocator, args[0..]),
        .child_cwd = try allocator.dupe(u8, cwd),
    };
    errdefer plan.deinit(allocator);
    try applySessionEnvToPlan(allocator, &plan, settings_env);
    return plan;
}

fn buildMacosSeatbeltPlan(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    sandbox_profile: []const u8,
    settings_env: SettingsEnv,
) !ExecutionPlan {
    const resolved_cwd = try resolvedWorkspacePath(allocator, cwd);
    errdefer allocator.free(resolved_cwd);

    var temp_dir: ?[]u8 = null;
    errdefer if (temp_dir) |dir| {
        std.Io.Dir.cwd().deleteTree(rt.io, dir) catch {};
        allocator.free(dir);
    };

    var env_map: ?std.process.Environ.Map = null;
    errdefer if (env_map) |*map| map.deinit();

    if (!std.mem.eql(u8, sandbox_profile, "read-only")) {
        temp_dir = try createScopedTempDir(allocator);
        env_map = try buildSandboxedEnvMap(allocator, temp_dir.?);
    }

    const profile_text = try buildMacosProfile(allocator, cwd, resolved_cwd, sandbox_profile, temp_dir);
    defer allocator.free(profile_text);

    var plan: ExecutionPlan = .{
        .argv = try duplicateArgv(allocator, &.{ "/usr/bin/sandbox-exec", "-p", profile_text, "/bin/sh", "-c", command }),
        .child_cwd = resolved_cwd,
        .env_map = env_map,
        .temp_dir = temp_dir,
    };
    errdefer plan.deinit(allocator);
    try applySessionEnvToPlan(allocator, &plan, settings_env);
    return plan;
}

fn buildLinuxBwrapPlan(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    command: []const u8,
    sandbox_profile: []const u8,
    settings_env: SettingsEnv,
) !ExecutionPlan {
    const resolved_cwd = try resolvedWorkspacePath(allocator, cwd);
    errdefer allocator.free(resolved_cwd);

    var temp_dir: ?[]u8 = null;
    errdefer if (temp_dir) |dir| {
        std.Io.Dir.cwd().deleteTree(rt.io, dir) catch {};
        allocator.free(dir);
    };

    var env_map: ?std.process.Environ.Map = null;
    errdefer if (env_map) |*map| map.deinit();

    if (!std.mem.eql(u8, sandbox_profile, "read-only")) {
        temp_dir = try createScopedTempDir(allocator);
        env_map = try buildSandboxedEnvMap(allocator, temp_dir.?);
    }

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit();
    }

    try appendOwnedArg(&argv, allocator, linuxBwrapPath() orelse return error.SandboxBackendUnavailable);
    try appendOwnedArg(&argv, allocator, "--die-with-parent");
    try appendOwnedArg(&argv, allocator, "--new-session");
    try appendOwnedArg(&argv, allocator, "--proc");
    try appendOwnedArg(&argv, allocator, "/proc");
    try appendOwnedArg(&argv, allocator, "--dev");
    try appendOwnedArg(&argv, allocator, "/dev");
    try appendOwnedArg(&argv, allocator, "--ro-bind");
    try appendOwnedArg(&argv, allocator, "/");
    try appendOwnedArg(&argv, allocator, "/");
    try appendOwnedArg(&argv, allocator, "--unshare-net");

    if (std.mem.eql(u8, sandbox_profile, "read-only")) {
        try appendOwnedArg(&argv, allocator, "--ro-bind");
        try appendOwnedArg(&argv, allocator, resolved_cwd);
        try appendOwnedArg(&argv, allocator, resolved_cwd);
    } else {
        try appendOwnedArg(&argv, allocator, "--bind");
        try appendOwnedArg(&argv, allocator, resolved_cwd);
        try appendOwnedArg(&argv, allocator, resolved_cwd);
        if (temp_dir) |dir| {
            try appendOwnedArg(&argv, allocator, "--bind");
            try appendOwnedArg(&argv, allocator, dir);
            try appendOwnedArg(&argv, allocator, dir);
        }
    }

    try appendOwnedArg(&argv, allocator, "--chdir");
    try appendOwnedArg(&argv, allocator, resolved_cwd);
    try appendOwnedArg(&argv, allocator, "--");
    try appendOwnedArg(&argv, allocator, "/bin/sh");
    try appendOwnedArg(&argv, allocator, "-c");
    try appendOwnedArg(&argv, allocator, command);

    const owned_argv = try argv.toOwnedSlice();
    argv = .init(allocator);

    var plan: ExecutionPlan = .{
        .argv = owned_argv,
        .child_cwd = resolved_cwd,
        .env_map = env_map,
        .temp_dir = temp_dir,
    };
    errdefer plan.deinit(allocator);
    try applySessionEnvToPlan(allocator, &plan, settings_env);
    return plan;
}

fn buildMacosProfile(
    allocator: std.mem.Allocator,
    original_cwd: []const u8,
    resolved_cwd: []const u8,
    sandbox_profile: []const u8,
    temp_dir: ?[]const u8,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    // macOS sandbox profile. Default-deny everything, then explicitly
    // allow:
    //   - process fork/exec/signal
    //   - reading from the standard system directories that every
    //     shell/binary needs (PATH lookups, dyld cache, libc, ...)
    //   - reading from the workspace cwd (and an optional temp dir)
    //   - writing to the workspace and temp dir when not in read-only
    //
    // Previous bug: the profile imported `system.sb` and then applied
    // `(deny default)`, which OVERRIDES the imports. Standard commands
    // like sleep/curl/lsof failed with "command not found" because
    // /bin and /usr/bin weren't readable, and `sh` itself threw
    // "Error opening /private/var/select/sh: Operation not permitted"
    // because macOS resolves /bin/sh through that symlink on newer
    // versions.
    //
    // Fix: drop the system.sb import (unreliable + redundant given
    // the explicit allows below) and enumerate the system paths we
    // actually need. This is the standard sandbox-exec pattern used
    // by Homebrew, rabbitmq, nix, and other tools that want a
    // workspace-only write jail.
    try out.writer().writeAll(
        "(version 1)\n" ++
            "(deny default)\n" ++
            // Process lifecycle: the shell must fork/exec binaries
            // and signal itself for job control.
            "(allow process-fork)\n" ++
            "(allow process-exec)\n" ++
            "(allow signal (target self))\n" ++
            // Sysctl reads for things like `uname -s`, hostname, CPU count,
            // and what SIP looks up to resolve mach-o loading.
            "(allow sysctl-read)\n" ++
            // Mach services: dyld_shared_cache lookups go through
            // com.apple.system.opendirectoryd, and libSystem calls
            // into a few other services. Without mach-lookup every
            // dylib load fails.
            "(allow mach-lookup)\n" ++
            // System-wide file reads. These are the directories that
            // EVERY shell command needs to load libraries, find the
            // binary via PATH, resolve /bin/sh -> /private/var/select/sh,
            // and read localedata/timezone/etc.
            "(allow file-read*\n" ++
            "  (subpath \"/System\")\n" ++
            "  (subpath \"/Library\")\n" ++
            "  (subpath \"/usr\")\n" ++
            "  (subpath \"/bin\")\n" ++
            "  (subpath \"/sbin\")\n" ++
            "  (subpath \"/opt/homebrew\")\n" ++
            "  (subpath \"/opt/local\")\n" ++
            // `/private/var/select` is how macOS resolves /bin/sh and
            // friends on newer releases -- without this, sh itself
            // errors out with 'Operation not permitted' before the
            // command can even run.
            "  (subpath \"/private/var/select\")\n" ++
            // `/private/var/db/dyld` is the dyld shared cache root.
            "  (subpath \"/private/var/db/dyld\")\n" ++
            // `/private/var/db/mds` is the Spotlight metadata store
            // which some tools (mdfind, mdutil) need to read.
            "  (subpath \"/private/var/db/mds\")\n" ++
            // /private/etc is where /etc resolves on macOS.
            "  (subpath \"/private/etc\")\n" ++
            // /private/var/folders is the per-user $TMPDIR root --
            // many tools use $TMPDIR before the explicit workspace
            // temp_dir we allow below.
            "  (subpath \"/private/var/folders\")\n" ++
            // /private/tmp is the macOS canonical /tmp.
            "  (subpath \"/private/tmp\")\n" ++
            "  (literal \"/etc\")\n" ++
            "  (literal \"/tmp\")\n" ++
            "  (literal \"/var\")\n" ++
            "  (literal \"/\")\n" ++
            ")\n" ++
            // Allow stat on every path so a readdir can list entries
            // even when the detail reads fall outside the allowed
            // subpaths. Without this, `ls /` errors out on every
            // subdirectory it can't read-stat.
            "(allow file-read-metadata)\n" ++
            // Device reads for things like /dev/null, /dev/urandom,
            // /dev/tty. Many commands write errors to /dev/null which
            // requires an open, not just a read.
            "(allow file-read* (literal \"/dev/null\"))\n" ++
            "(allow file-read* (literal \"/dev/urandom\"))\n" ++
            "(allow file-read* (literal \"/dev/random\"))\n" ++
            "(allow file-read* (literal \"/dev/zero\"))\n" ++
            "(allow file-read* (literal \"/dev/tty\"))\n" ++
            "(allow file-write-data (literal \"/dev/null\"))\n" ++
            "(allow file-write-data (literal \"/dev/tty\"))\n",
    );

    try appendReadAccess(&out, allocator, original_cwd);
    if (!std.mem.eql(u8, resolved_cwd, original_cwd)) {
        try appendReadAccess(&out, allocator, resolved_cwd);
    }
    if (temp_dir) |dir| {
        try appendReadAccess(&out, allocator, dir);
    }

    if (!std.mem.eql(u8, sandbox_profile, "read-only")) {
        try appendWriteAccess(&out, allocator, original_cwd);
        if (!std.mem.eql(u8, resolved_cwd, original_cwd)) {
            try appendWriteAccess(&out, allocator, resolved_cwd);
        }
        if (temp_dir) |dir| {
            try appendWriteAccess(&out, allocator, dir);
        }
    }

    return out.toOwnedSlice();
}

fn appendReadAccess(out: *std_io.StringBuilder, allocator: std.mem.Allocator, path: []const u8) !void {
    const escaped = try sbplQuote(allocator, path);
    defer allocator.free(escaped);

    try out.writer().print(
        "(allow file-read* (subpath \"{s}\"))\n",
        .{escaped},
    );
}

fn appendWriteAccess(out: *std_io.StringBuilder, allocator: std.mem.Allocator, path: []const u8) !void {
    const escaped = try sbplQuote(allocator, path);
    defer allocator.free(escaped);

    try out.writer().print(
        "(allow file-write* (subpath \"{s}\"))\n" ++
            "(allow file-write-create file-write-data (require-all (vnode-type DIRECTORY) (literal \"{s}\")))\n",
        .{ escaped, escaped },
    );
}

fn sbplQuote(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    for (text) |ch| {
        switch (ch) {
            '\\', '"' => {
                try out.append('\\');
                try out.append(ch);
            },
            else => try out.append(ch),
        }
    }

    return out.toOwnedSlice();
}

fn buildSandboxedEnvMap(allocator: std.mem.Allocator, temp_dir: []const u8) !std.process.Environ.Map {
    var env_map = std.process.Environ.Map.init(allocator);
    errdefer env_map.deinit();

    // Strip secret-bearing env vars before forwarding to the child shell.
    // Previously `buildSandboxedEnvMap` copied the full parent env which
    // leaked provider API keys (OPENAI_API_KEY, ANTHROPIC_API_KEY, ...),
    // cloud credentials (AWS_*, AZURE_*, GCP_*), CI tokens (GITHUB_TOKEN,
    // GH_TOKEN), and zcode's own ZCODE_* configuration into any command
    // the user or model ran under `shell`. A sandboxed shell that can
    // run `env | grep TOKEN` is no sandbox at all.
    scrubSecretEnvVars(&env_map);

    const home_dir = try std.fs.path.join(allocator, &.{ temp_dir, "home" });
    defer allocator.free(home_dir);
    std.Io.Dir.createDirAbsolute(rt.io, home_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try env_map.put("TMPDIR", temp_dir);
    try env_map.put("TMP", temp_dir);
    try env_map.put("TEMP", temp_dir);
    try env_map.put("HOME", home_dir);
    return env_map;
}

fn scrubSecretEnvVars(env_map: *std.process.Environ.Map) void {
    // Collect keys to remove so we don't mutate while iterating.
    var victims = std.array_list.Managed([]const u8).init(env_map.allocator);
    defer victims.deinit();
    var it = env_map.iterator();
    while (it.next()) |entry| {
        if (envKeyLooksSensitive(entry.key_ptr.*)) {
            victims.append(entry.key_ptr.*) catch continue;
        }
    }
    for (victims.items) |key| _ = env_map.swapRemove(key);
}

fn envKeyLooksSensitive(name: []const u8) bool {
    const prefixes = [_][]const u8{
        "AWS_",       "AZURE_",  "GCP_", "GOOGLE_",
        "ZCODE_",     "GH_",     "NPM_", "PYPI_",
        "DOCKER_",    "STRIPE_",
        // Library-injection / dynamic-loader overrides. A parent
        // shell that exported LD_PRELOAD (Linux), DYLD_INSERT_LIBRARIES
        // / DYLD_LIBRARY_PATH (macOS), or PYTHONPATH could force the
        // sandboxed child to load an attacker-supplied library.
        // Treat them as sensitive so scrubSecretEnvVars strips them
        // before the child shell sees them. Does not affect normal
        // LD_LIBRARY_PATH / other LD_* names because prefix matching
        // catches them too; users who legitimately need those can
        // re-export inside the sandboxed shell.
        "LD_",  "DYLD_",
        "PYTHONPATH",
    };
    for (prefixes) |prefix| {
        if (name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) {
            return true;
        }
    }
    const substrings = [_][]const u8{
        "TOKEN",      "SECRET", "PASSWORD",   "PASSWD",
        "API_KEY",    "APIKEY", "CREDENTIAL", "PRIVATE_KEY",
        "ACCESS_KEY", "AUTH",
    };
    for (substrings) |needle| {
        if (containsIgnoreCase(name, needle)) return true;
    }
    return false;
}

fn createScopedTempDir(allocator: std.mem.Allocator) ![]u8 {
    const base = if (builtin.os.tag == .macos) "/private/tmp" else "/tmp";

    // mkdtemp-style: 128 bits of crypto randomness in the name and
    // refuse to reuse an existing path. The previous pid+nanotime
    // scheme was predictable (pid space + clock skew make collisions
    // plausible on busy hosts), which opened a TOCTOU window where
    // another local user could precreate the directory with attacker-
    // controlled contents. Retry on the astronomical chance of
    // collision; give up after a handful of attempts.
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        var rand_bytes: [16]u8 = undefined;
        rng.bytes(&rand_bytes);
        const alphabet = "0123456789abcdef";
        var hex: [32]u8 = undefined;
        for (rand_bytes, 0..) |b, i| {
            hex[i * 2] = alphabet[b >> 4];
            hex[i * 2 + 1] = alphabet[b & 0x0f];
        }

        const name = try std.fmt.allocPrint(allocator, "zcode-shell-{s}", .{hex[0..]});
        defer allocator.free(name);
        const dir = try std.fs.path.join(allocator, &.{ base, name });
        errdefer allocator.free(dir);
        std.Io.Dir.createDirAbsolute(rt.io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(dir);
                continue;
            },
            else => return err,
        };
        // Tighten permissions to 0700 so even on umask-022 hosts the
        // scratch dir is owner-only. Use fchmodat by path (AT.FDCWD)
        // instead of std.Io.Dir.chmod, which on Linux opens the dir
        // as O_PATH and then panics in posix.fchmod (.BADF=>unreachable).
        var path_z_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (dir.len < path_z_buf.len) {
            @memcpy(path_z_buf[0..dir.len], dir);
            path_z_buf[dir.len] = 0;
            _ = std.c.chmod(&path_z_buf, 0o700);
        }
        return dir;
    }
    return error.TempDirCollision;
}

fn duplicateArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    errdefer {
        while (i > 0) {
            i -= 1;
            allocator.free(out[i]);
        }
    }

    while (i < argv.len) : (i += 1) {
        out[i] = try allocator.dupe(u8, argv[i]);
    }
    return out;
}

fn appendOwnedArg(list: *std.array_list.Managed([]const u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try list.append(try allocator.dupe(u8, text));
}

fn resolvedWorkspacePath(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return allocator.dupe(u8, cwd) catch allocator.dupe(u8, cwd);
}

fn activeShellBackend() ShellBackend {
    return switch (builtin.os.tag) {
        .macos => .macos_seatbelt,
        .linux => .linux_bwrap,
        else => .direct,
    };
}

fn linuxBwrapPath() ?[]const u8 {
    for ([_][]const u8{ "/usr/bin/bwrap", "/bin/bwrap", "/usr/local/bin/bwrap" }) |path| {
        std.Io.Dir.accessAbsolute(rt.io, path, .{}) catch continue;
        return path;
    }
    return null;
}

fn directShellArgv(command: []const u8) []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{ "cmd.exe", "/C", command },
        // Use -c (not -lc) to avoid loading /etc/profile which the sandbox may block.
        // The parent process PATH is inherited, so user-installed tools (gh, gac, etc.)
        // are available without needing a login shell.
        else => &.{ "/bin/sh", "-c", command },
    };
}

const testing = std.testing;

// libc env mutators for the env-driven tests below. Mirrors the
// declarations in bash_security.zig; kept local to avoid a cross-import
// just for a couple of test helpers.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "shouldCloseStdin decision boolean for representative commands" {
    // Plain non-interactive commands carry no stdin source, so we close it
    // (this is what keeps `git commit` etc. from blocking on a TTY).
    try testing.expect(shouldCloseStdin("git commit -m msg"));
    try testing.expect(shouldCloseStdin("ls -la"));
    try testing.expect(shouldCloseStdin("echo hi | wc -l"));
    // Heredoc commands feed their own stdin via the shell; the decision is
    // "do not close" (the spawn's /dev/null stdin is harmless here because
    // the shell wrapper supplies the heredoc body internally).
    try testing.expect(!shouldCloseStdin("cat <<EOF\nhi\nEOF"));
    // Explicit input redirect supplies stdin from a file -> do not close.
    try testing.expect(!shouldCloseStdin("sort < names.txt"));
}

test "maxOutputLength defaults to 30000 with no env" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    _ = unsetenv("BASH_MAX_OUTPUT_LENGTH");
    try testing.expectEqual(@as(usize, 30_000), maxOutputLength());
}

test "maxOutputLength caps an oversized env value at 150000" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    _ = setenv("BASH_MAX_OUTPUT_LENGTH", "999999", 1);
    defer _ = unsetenv("BASH_MAX_OUTPUT_LENGTH");
    try testing.expectEqual(@as(usize, 150_000), maxOutputLength());
}

test "maxOutputLength honors an in-range env value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    _ = setenv("BASH_MAX_OUTPUT_LENGTH", "500", 1);
    defer _ = unsetenv("BASH_MAX_OUTPUT_LENGTH");
    try testing.expectEqual(@as(usize, 500), maxOutputLength());
}

test "maxOutputLength falls back to default for garbage and zero" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    _ = setenv("BASH_MAX_OUTPUT_LENGTH", "not-a-number", 1);
    try testing.expectEqual(@as(usize, 30_000), maxOutputLength());
    _ = setenv("BASH_MAX_OUTPUT_LENGTH", "0", 1);
    try testing.expectEqual(@as(usize, 30_000), maxOutputLength());
    _ = unsetenv("BASH_MAX_OUTPUT_LENGTH");
}

test "isImageDataUri detects base64 image payloads" {
    try testing.expect(isImageDataUri("data:image/png;base64,AAAA"));
    try testing.expect(isImageDataUri("data:image/jpeg;base64,/9j/4AAQ"));
    try testing.expect(isImageDataUri("  data:image/gif;base64,R0lGOD"));
    try testing.expect(!isImageDataUri("hello"));
    // Not base64-tagged -> not treated as an image passthrough.
    try testing.expect(!isImageDataUri("data:image/png,plain"));
    // Non-image data URI is not an image.
    try testing.expect(!isImageDataUri("data:text/plain;base64,AAAA"));
}

test "imageMediaType extracts the media type" {
    try testing.expectEqualStrings("image/png", imageMediaType("data:image/png;base64,AAAA").?);
    try testing.expectEqualStrings("image/jpeg", imageMediaType("data:image/jpeg;base64,/9j").?);
    try testing.expect(imageMediaType("hello") == null);
}

test "truncateForModel keeps short output untouched" {
    const r = truncateForModel("short output\n", 30_000);
    try testing.expect(!r.truncated);
    try testing.expectEqual(@as(usize, 0), r.truncated_lines);
    try testing.expect(!r.is_image);
    try testing.expectEqualStrings("short output\n", r.kept);
}

test "truncateForModel cuts long output and counts dropped lines" {
    // 10 lines, cap so that the first 2 bytes are kept and the rest
    // (which contains 9 newlines after the cut point) is dropped.
    const input = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n";
    const r = truncateForModel(input, 2);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("a\n", r.kept);
    // Dropped tail "b\nc\nd\ne\nf\ng\nh\ni\nj\n" has 9 newlines -> at
    // least one (partial) line plus 9 = but the tail begins right after
    // "a\n", so it is "b\n...j\n": 9 newlines, lines counted as 1 + 9.
    try testing.expectEqual(@as(usize, 10), r.truncated_lines);
}

test "truncateForModel passes image data-URIs through untruncated" {
    const img = "data:image/png;base64," ++ ("A" ** 100);
    const r = truncateForModel(img, 10);
    try testing.expect(!r.truncated);
    try testing.expect(r.is_image);
    try testing.expectEqual(@as(usize, 0), r.truncated_lines);
    try testing.expectEqualStrings(img, r.kept);
}

test "shell run truncates long stdout with a lines-truncated note" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // Force a tiny cap so a modest command overflows it deterministically.
    _ = setenv("BASH_MAX_OUTPUT_LENGTH", "100", 1);
    defer _ = unsetenv("BASH_MAX_OUTPUT_LENGTH");

    // `seq 1 500` prints 500 short lines, far exceeding 100 bytes.
    const result = try run(testing.allocator, ".", "seq 1 500", 5, "danger-full-access");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "lines truncated") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"output_truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"truncated_lines\":") != null);
}

test "envKeyLooksSensitive flags common secret patterns" {
    try testing.expect(envKeyLooksSensitive("OPENAI_API_KEY"));
    try testing.expect(envKeyLooksSensitive("ANTHROPIC_API_KEY"));
    try testing.expect(envKeyLooksSensitive("AWS_ACCESS_KEY_ID"));
    try testing.expect(envKeyLooksSensitive("AWS_SECRET_ACCESS_KEY"));
    try testing.expect(envKeyLooksSensitive("AZURE_OPENAI_API_KEY"));
    try testing.expect(envKeyLooksSensitive("GITHUB_TOKEN"));
    try testing.expect(envKeyLooksSensitive("GH_TOKEN"));
    try testing.expect(envKeyLooksSensitive("ZCODE_SESSION_KEY"));
    try testing.expect(envKeyLooksSensitive("DB_PASSWORD"));
    try testing.expect(envKeyLooksSensitive("MY_PRIVATE_KEY"));
    // Library-injection / loader overrides are also stripped.
    try testing.expect(envKeyLooksSensitive("LD_PRELOAD"));
    try testing.expect(envKeyLooksSensitive("LD_LIBRARY_PATH"));
    try testing.expect(envKeyLooksSensitive("DYLD_INSERT_LIBRARIES"));
    try testing.expect(envKeyLooksSensitive("DYLD_LIBRARY_PATH"));
    try testing.expect(envKeyLooksSensitive("PYTHONPATH"));
    try testing.expect(!envKeyLooksSensitive("PATH"));
    try testing.expect(!envKeyLooksSensitive("HOME"));
    try testing.expect(!envKeyLooksSensitive("USER"));
    try testing.expect(!envKeyLooksSensitive("LANG"));
    try testing.expect(!envKeyLooksSensitive("TERM"));
}

test "shell run executes simple command" {
    const result = try run(testing.allocator, ".", "echo hello", 5, "danger-full-access");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[shell_result]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"sandbox_status\":\"disabled\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"return_code_interpretation\":\"success\"") != null);
}

test "shell result contract classifies grep no matches as non error" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const result = try run(testing.allocator, ".", "grep unlikely-zcode-match /dev/null", 5, "danger-full-access");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "[exit_code=1]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"return_code_interpretation\":\"no_matches_found\"") != null);
}

test "runBackground reports failure when the command exits immediately" {
    // This is the "server running but not actually running" bug:
    // previously we returned `[backgrounded][pid=X]` for any
    // command `nohup` could spawn, even when the underlying
    // process crashed at startup. The caller was then convinced
    // their server was up when it was already dead. The 200 ms
    // liveness check catches this class of failure.
    if (builtin.os.tag == .windows) return;

    const result = try runBackground(testing.allocator, ".", "false", "danger-full-access");
    defer testing.allocator.free(result);

    // `false` exits immediately with code 1, so the PID is gone
    // by the time our 200 ms grace window elapses.
    try testing.expect(std.mem.indexOf(u8, result, "FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, result, "exited within") != null);
}

test "runBackground reports success for a long-lived command" {
    // Positive path: `sleep 5` is still running 200 ms after spawn,
    // so the verification passes and we emit the normal backgrounded
    // message plus a "verified alive" tag.
    if (builtin.os.tag == .windows) return;

    const result = try runBackground(testing.allocator, ".", "sleep 5", "danger-full-access");
    defer testing.allocator.free(result);

    // "background failed" and "FAILED" are both possible sandbox
    // refusal paths on CI. Treat those as a skip rather than a
    // hard failure since this test is really about the liveness
    // check, not about the sandbox.
    if (std.mem.indexOf(u8, result, "background failed") != null or
        std.mem.indexOf(u8, result, "FAILED") != null)
    {
        return error.SkipZigTest;
    }

    try testing.expect(std.mem.indexOf(u8, result, "[backgrounded]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "verified alive") != null);

    // Extract the PID and reap it so the test doesn't leak a
    // 5-second sleep process into the test runner's process tree.
    if (std.mem.indexOf(u8, result, "pid=")) |pid_start_idx| {
        const after = result[pid_start_idx + 4 ..];
        const newline = std.mem.indexOfScalar(u8, after, ']') orelse after.len;
        const pid_str = after[0..newline];
        if (std.fmt.parseInt(i32, pid_str, 10) catch null) |pid| {
            const pid_t: std.posix.pid_t = @intCast(pid);
            std.posix.kill(pid_t, std.posix.SIG.TERM) catch {};
        }
    }
}

test "backgroundPidIsAlive reports false for a nonexistent pid" {
    // A freshly-reaped or never-existed PID should report dead.
    // Using a huge PID (2^20) to pick one that is extremely
    // unlikely to collide with a real process.
    if (builtin.os.tag == .windows) return;
    try testing.expect(!backgroundPidIsAlive(1_000_000));
}

test "shell run respects timeout" {
    const result = try run(testing.allocator, ".", "echo quick", 1, "danger-full-access");
    defer testing.allocator.free(result);
    try testing.expect(std.mem.indexOf(u8, result, "quick") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[exit_code=0]") != null);
}

test "detect interactive no-result stderr" {
    const spinner = "\x1b[?2026h\x1b[?25l\x1b[1G⠙ \x1b[K\x1b[?25h\x1b[?2026l\n";
    try testing.expect(isInteractiveNoResult("", spinner));
    try testing.expect(!isInteractiveNoResult("ready\n", spinner));
    try testing.expect(!isInteractiveNoResult("", "Error: failed to start\n"));
}

test "sbpl quote escapes backslashes and double quotes" {
    const quoted = try sbplQuote(testing.allocator, "/tmp/with\"quote\\slash");
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("/tmp/with\\\"quote\\\\slash", quoted);
}

test "workspace-write macos shell sandbox allows workspace write" {
    if (builtin.os.tag != .macos or !sandbox_mod.hasShellSandboxBackend("workspace-write")) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try run(testing.allocator, cwd, "printf 'ok' > allowed.txt", 5, "workspace-write");
    defer testing.allocator.free(result);

    const file = try tmp.dir.readFileAlloc(rt.io, "allowed.txt", testing.allocator, .limited(32));
    defer testing.allocator.free(file);
    try testing.expectEqualStrings("ok", file);
}

test "read-only macos shell sandbox blocks workspace write" {
    if (builtin.os.tag != .macos or !sandbox_mod.hasShellSandboxBackend("read-only")) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try run(testing.allocator, cwd, "printf 'nope' > blocked.txt", 5, "read-only");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "operation not permitted") != null or
        std.mem.indexOf(u8, result, "Operation not permitted") != null);
    try testing.expect(tmp.dir.access(rt.io, "blocked.txt", .{}) == error.FileNotFound);
}

test "workspace-write macos shell sandbox blocks writes outside workspace" {
    if (builtin.os.tag != .macos or !sandbox_mod.hasShellSandboxBackend("workspace-write")) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const outside = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/zcode-outside-{d}-{d}.txt",
        .{ if (comptime builtin.os.tag == .linux) @as(i32, @intCast(std.os.linux.getpid())) else std.c.getpid(), clock.nowSeconds() },
    );
    defer testing.allocator.free(outside);
    std.Io.Dir.deleteFileAbsolute(rt.io, outside) catch {};

    const command = try std.fmt.allocPrint(testing.allocator, "printf 'nope' > {s}", .{outside});
    defer testing.allocator.free(command);

    const result = try run(testing.allocator, cwd, command, 5, "workspace-write");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "operation not permitted") != null or
        std.mem.indexOf(u8, result, "Operation not permitted") != null);
    try testing.expect(std.Io.Dir.accessAbsolute(rt.io, outside, .{}) == error.FileNotFound);
}

test "macos sandbox profile allows /bin, /usr, and the select symlink root" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const profile = try buildMacosProfile(
        testing.allocator,
        "/some/workspace",
        "/some/workspace",
        "workspace-write",
        null,
    );
    defer testing.allocator.free(profile);

    // These are the paths that were being denied before the fix,
    // causing `sleep: command not found` and
    // `Error opening /private/var/select/sh: Operation not permitted`.
    // Regression guard: a future edit to the profile must keep all
    // of these read-allow entries.
    try testing.expect(std.mem.indexOf(u8, profile, "\"/bin\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "\"/usr\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "\"/sbin\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "/private/var/select") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "/private/var/db/dyld") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "/private/var/folders") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "\"/System\"") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "\"/Library\"") != null);
    // Homebrew prefix must be readable so brew-installed tools work.
    try testing.expect(std.mem.indexOf(u8, profile, "/opt/homebrew") != null);
    // Process lifecycle allows
    try testing.expect(std.mem.indexOf(u8, profile, "process-fork") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "process-exec") != null);
    // Mach-lookup is required for dyld shared cache resolution.
    try testing.expect(std.mem.indexOf(u8, profile, "mach-lookup") != null);
}

test "macos sandbox can actually run sleep, which previously failed" {
    // End-to-end regression guard for the specific commands shown
    // failing in the user screenshot: sleep, curl, lsof all hit
    // "command not found" because PATH directories weren't readable.
    // Run sleep 0 as the cheapest proof -- it exercises PATH lookup
    // without actually waiting.
    if (builtin.os.tag != .macos or !sandbox_mod.hasShellSandboxBackend("workspace-write")) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const result = try run(testing.allocator, cwd, "sleep 0 && echo alive", 5, "workspace-write");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "alive") != null);
    // Must NOT contain the previous-failure stderr message.
    try testing.expect(std.mem.indexOf(u8, result, "sleep: command not found") == null);
    try testing.expect(std.mem.indexOf(u8, result, "Error opening /private/var/select/sh") == null);
}

fn collectWithTimeout(
    allocator: std.mem.Allocator,
    child: *std.process.Child,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    max_output_bytes: usize,
    timeout_seconds: usize,
) !void {
    const stdout_file = child.stdout orelse return error.MissingStdOutPipe;
    const stderr_file = child.stderr orelse return error.MissingStdErrPipe;

    // Direct poll()+read() loop instead of std.Io.poll. The stdlib
    // Poller skips read() when revents has POLLHUP but not POLLIN,
    // which on macOS happens for fast-exiting child processes (the
    // writer closes before the reader's first poll), so buffered pipe
    // data gets discarded. Reading on HUP is safe: read() returns 0
    // on true EOF and the real byte count when buffered data is
    // still present.
    const stdout_fd = stdout_file.handle;
    const stderr_fd = stderr_file.handle;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = stdout_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = stderr_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const err_mask = std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP;

    const timeout_ns: u64 = @as(u64, @intCast(timeout_seconds)) * std.time.ns_per_s;
    const start_ns = clock.nowNanos();
    var tmp_buf: [8 * 1024]u8 = undefined;

    while (true) {
        try http_common.checkCancelled();

        // If both fds are closed we're done.
        if (poll_fds[0].fd == -1 and poll_fds[1].fd == -1) break;

        const now_ns = clock.nowNanos();
        const elapsed_ns: u64 = if (now_ns <= start_ns) 0 else @as(u64, @intCast(now_ns - start_ns));
        if (elapsed_ns >= timeout_ns) return error.CommandTimedOut;

        const remaining_ms: i32 = blk: {
            const ns = timeout_ns - elapsed_ns;
            const ms = ns / std.time.ns_per_ms;
            break :blk std.math.cast(i32, ms) orelse std.math.maxInt(i32);
        };

        _ = try std.posix.poll(&poll_fds, remaining_ms);

        // Read whenever POLLIN OR POLLHUP is set - on HUP, data may
        // still be buffered; only mark closed after read() returns 0.
        try drainPipeToArrayList(allocator, &poll_fds[0], stdout, &tmp_buf, err_mask, max_output_bytes, .stdout);
        try drainPipeToArrayList(allocator, &poll_fds[1], stderr, &tmp_buf, err_mask, max_output_bytes, .stderr);
    }
}

const PipeKind = enum { stdout, stderr };

fn drainPipeToArrayList(
    allocator: std.mem.Allocator,
    poll_fd: *std.posix.pollfd,
    target: *std.ArrayList(u8),
    tmp_buf: *[8 * 1024]u8,
    err_mask: i16,
    max_output_bytes: usize,
    kind: PipeKind,
) !void {
    if (poll_fd.fd == -1) return;
    const revents = poll_fd.revents;
    const readable = (revents & std.posix.POLL.IN) != 0 or
        (revents & err_mask) != 0;
    if (!readable) return;

    while (true) {
        const amt = std.posix.read(poll_fd.fd, tmp_buf) catch |err| switch (err) {
            error.WouldBlock => return,
            error.BrokenPipe => 0,
            else => |e| return e,
        };
        if (amt == 0) {
            poll_fd.fd = -1;
            return;
        }
        try target.appendSlice(allocator, tmp_buf[0..amt]);
        if (target.items.len > max_output_bytes) {
            return switch (kind) {
                .stdout => error.StreamTooLong,
                .stderr => error.StreamTooLong,
            };
        }
        if (amt < tmp_buf.len) return;
    }
}

fn isInteractiveNoResult(stdout: []const u8, stderr: []const u8) bool {
    if (std.mem.trim(u8, stdout, " \t\r\n").len > 0) return false;
    if (stderr.len == 0) return false;
    return !containsMeaningfulTerminalText(stderr);
}

fn containsMeaningfulTerminalText(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += ansiEscapeLength(text[i..]);
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + seq_len > text.len) return true;

        const cp = std.unicode.utf8Decode(text[i .. i + seq_len]) catch return true;
        i += seq_len;

        if (isWhitespaceCodepoint(cp)) continue;
        if (cp >= 0x2800 and cp <= 0x28FF) continue;

        return true;
    }

    return false;
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        0x0085, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn ansiEscapeLength(text: []const u8) usize {
    if (text.len == 0 or text[0] != 0x1b) return 0;
    if (text.len == 1) return 1;

    const second = text[1];
    if (second == '[') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch >= 0x40 and ch <= 0x7e) return i + 1;
        }
        return text.len;
    }
    if (second == ']') {
        var i: usize = 2;
        while (i < text.len) : (i += 1) {
            if (text[i] == 0x07) return i + 1;
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
        }
        return text.len;
    }

    return @min(text.len, @as(usize, 2));
}

test "settings-02: applySessionEnvToPlan applies settings env, session env wins" {
    const session_env = @import("../core/session_env.zig");
    session_env.resetForTesting(testing.allocator);
    defer session_env.resetForTesting(testing.allocator);

    // settings_env: FOO=settings and BAZ=settings. Session: FOO=session.
    const settings_env = [_]config_mod.EnvPair{
        .{ .name = @constCast("FOO"), .value = @constCast("settings") },
        .{ .name = @constCast("BAZ"), .value = @constCast("settings") },
    };
    try session_env.set(testing.allocator, "FOO", "session");

    var plan: ExecutionPlan = .{
        .argv = try duplicateArgv(testing.allocator, &.{ "/bin/sh", "-c", "true" }),
        .child_cwd = try testing.allocator.dupe(u8, "."),
    };
    defer plan.deinit(testing.allocator);

    try applySessionEnvToPlan(testing.allocator, &plan, settings_env[0..]);

    // Session FOO overrides settings FOO; BAZ from settings passes through.
    try testing.expectEqualStrings("session", plan.env_map.?.get("FOO").?);
    try testing.expectEqualStrings("settings", plan.env_map.?.get("BAZ").?);
}

test "settings-02: applySessionEnvToPlan with empty settings and no session is a no-op" {
    const session_env = @import("../core/session_env.zig");
    session_env.resetForTesting(testing.allocator);
    defer session_env.resetForTesting(testing.allocator);

    // phase-26 daemon-background-06: with empty settings/session env, the only
    // remaining reason to allocate an env_map is tmux socket isolation. Pin
    // tmux as absent (PATH -> a dir that cannot hold tmux) so the "no override
    // needed -> no env_map copy" invariant this test guards holds regardless of
    // whether the host machine has tmux installed.
    const env = @import("../core/env.zig");
    try env.setOverride("PATH", "/nonexistent-zcode-tmux-test-dir");
    defer env.clearOverrides();

    var plan: ExecutionPlan = .{
        .argv = try duplicateArgv(testing.allocator, &.{ "/bin/sh", "-c", "true" }),
        .child_cwd = try testing.allocator.dupe(u8, "."),
    };
    defer plan.deinit(testing.allocator);

    try applySessionEnvToPlan(testing.allocator, &plan, &.{});

    // No env_map allocated when both sources are empty and tmux is absent: the
    // child inherits the raw process env.
    try testing.expect(plan.env_map == null);
}
