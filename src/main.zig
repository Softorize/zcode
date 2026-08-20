const std = @import("std");
const clock = @import("core/clock.zig");
const std_io = @import("core/std_io.zig");
const rt = @import("zcode_runtime");
const build_options = @import("build_options");
const log_runtime = @import("core/log_runtime.zig");

/// Install our runtime-configurable log function so `--log-level`
/// and `--log-format` can redirect std.log output at startup without
/// a rebuild.
pub const std_options: std.Options = .{
    .logFn = log_runtime.logFn,
};

const cli = @import("cli/args.zig");
const config_mod = @import("core/config.zig");
const logger_mod = @import("core/logger.zig");
const model_fallback_suggestion = @import("core/model_fallback_suggestion.zig");
const control_plane = @import("core/control_plane.zig");
const enterprise_doctor = @import("core/enterprise_doctor.zig");
const file_integrity = @import("core/file_integrity.zig");
const jwks_cache = @import("core/jwks_cache.zig");
const policy_mod = @import("policy/policy.zig");
const session_store = @import("session/store.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");

const session_mgmt = @import("session_mgmt.zig");
const sdk_headless = @import("sdk/headless.zig");
const sdk_output = @import("sdk/output.zig");
const sdk_stdout_guard = @import("sdk/stdout_guard.zig");
const api_server = @import("api_server.zig");
const update = @import("update.zig");
const remote_daemon = @import("remote_daemon.zig");
const kairos = @import("kairos.zig");
const bg_cmds = @import("bg_cmds.zig");
const tool_dispatch = @import("tools/tool_dispatch.zig");

// Reachable-from-main registry for orphan utility modules so their
// tests run under `zig build test`. The Zig 0.15 test runner only
// discovers files transitively reachable from the test root, and these
// pure-utility modules are not imported by any production code path
// yet (they exist for callers in subsequent passes). Keep this block
// in sync when adding new util modules so their tests aren't silently
// skipped.
comptime {
    _ = @import("core/cache_paths.zig");
    _ = @import("core/env_validation.zig");
    _ = @import("core/display_tags.zig");
    _ = @import("core/circular_buffer.zig");
    _ = @import("core/error_log.zig");
    // prevent_sleep is imported inside function bodies in
    // agent_runtime.zig, which doesn't reach the test root, so
    // its tests need an explicit registration here.
    _ = @import("core/prevent_sleep.zig");
    // dream is imported inside function bodies in agent_runtime.zig and
    // repl_commands.zig, which don't reach the test root, so its tests
    // (touchedSinceCount, shouldAutoDream, lastConsolidatedAtSec) need an
    // explicit registration here (background-svc-01).
    _ = @import("core/dream.zig");
    // tool_use_summary is a self-contained background-service helper (no live
    // call site yet, see plan task 14.17), so its prompt/truncation/generate
    // tests need an explicit registration here.
    _ = @import("core/tool_use_summary.zig");
    // web_preapproved is imported inside the policy classifier
    // (policy.zig function body); its tests need the registration.
    _ = @import("core/web_preapproved.zig");
    // url_host is imported by tools/web.zig for cross-host redirect
    // detection; register here so its tests are discovered.
    _ = @import("core/url_host.zig");
    // web_artifacts is imported by tools/web.zig for binary/PDF
    // persistence (Phase 9 Task 3); register so its tests are discovered.
    _ = @import("core/web_artifacts.zig");
    // lsp_diagnostics holds the session-scoped diagnostic baseline store and
    // the publishDiagnostics parser (Phase 9 Task 10 / analytics-09); register
    // so its tests are discovered.
    _ = @import("core/lsp_diagnostics.zig");
    // Persistent LSP server manager subsystem (parity phase 19, lsp-02): a
    // process-lifetime singleton owning long-lived language-server processes,
    // their background reader threads, and shared JSON-RPC framing. Register so
    // their tests are discovered.
    _ = @import("core/lsp/protocol.zig");
    _ = @import("core/lsp/server_instance.zig");
    _ = @import("core/lsp/manager.zig");
    // registry.zig is the passive-diagnostics registry (parity phase 19,
    // lsp-01): publishDiagnostics storage + drain + attachment rendering.
    _ = @import("core/lsp/registry.zig");
    // config.zig (parity phase 19, lsp-07): built-in default server table
    // merged with optional plugin-sourced overrides.
    _ = @import("core/lsp/config.zig");
    // html_to_text is imported by tools/web.zig. tools/ is walked by
    // the test root, but adding the explicit registration here keeps
    // the orphan-discovery safety net consistent across passes.
    _ = @import("core/html_to_text.zig");
    // at_file_refs is imported by agent_runtime.zig (which IS
    // walked by the test root), but registering here keeps the
    // orphan-discovery pattern consistent.
    _ = @import("core/at_file_refs.zig");
    // word_diff is a new utility not yet imported by any production
    // caller; register it so its tests run under `zig build test`.
    _ = @import("core/word_diff.zig");
    _ = @import("core/thinking_render.zig");
    // terminal_response is a pure parser for inbound terminal-response
    // escape sequences (DECRPM/DA1/DA2/kitty-flags/DSR). Register so its
    // tests run under `zig build test`.
    _ = @import("core/terminal_response.zig");
    // progress_osc builds OSC 9;4 taskbar progress sequences (terminal-04).
    // Register so its tests run under `zig build test`.
    _ = @import("core/progress_osc.zig");
    // terminal_caps gained the XTVERSION terminal-name probe state
    // (setXtversionName / isXtermJs / supportsExtendedKeys) in terminal-02.
    // Register so its tests run under `zig build test`.
    _ = @import("core/terminal_caps.zig");
    // color_level resolves the terminal color level with the tmux
    // truecolor->256 clamp + xterm.js boost (terminal-07). Register so its
    // tests run under `zig build test`.
    _ = @import("core/color_level.zig");
    // agent_color is the per-session prompt-bar accent palette (/color,
    // commands-sweep-03). Pure palette/reset-alias validation; register so
    // its tests run under `zig build test`.
    _ = @import("core/agent_color.zig");
    // ansi256 quantizes truecolor RGB to the xterm-256 palette (terminal-08).
    // Backs color_level's tmux clamp when the runtime-rewrite route is used;
    // standalone utility otherwise. Register so its tests run under
    // `zig build test`.
    _ = @import("core/ansi256.zig");
    // error_hints is imported from a few call sites but registering
    // here keeps the orphan-discovery pattern consistent and its
    // tests guaranteed under `zig build test`.
    _ = @import("core/error_hints.zig");
    _ = @import("core/env_registry.zig");
    _ = @import("core/wcwidth.zig");
    // Keychain is a leaf utility consumed by provider-key resolution
    // once callers opt in; register here so its tests run even while
    // the integration is still being rolled out.
    _ = @import("core/keychain.zig");
    _ = @import("policy/rbac.zig");
    _ = @import("core/oidc.zig");
    _ = @import("core/file_integrity.zig");
    _ = @import("core/jwks_cache.zig");
    _ = @import("core/enterprise_doctor.zig");
    _ = @import("core/log_runtime.zig");
    _ = @import("core/assistant_render.zig");
    _ = @import("core/display_safe.zig");
    _ = @import("core/resource_limits.zig");
    _ = @import("core/egress.zig");
    _ = @import("core/gitignore.zig");
    _ = @import("core/deep_link.zig");
    _ = @import("core/otel_export.zig");
    _ = @import("core/telemetry_attributes.zig");
    _ = @import("core/prompt_analysis.zig");
    _ = @import("core/autocompact_threshold.zig");
    _ = @import("core/post_compact_files.zig");
    _ = @import("core/context_management.zig");
    _ = @import("core/keep_window_compact.zig");
    // KAIROS modules. cron.zig is only reached through function-body imports
    // (tool_dispatch.getCronStore), so its tests — and the new per-project
    // cwd tests — need explicit registration. kairos.zig / kairos_lock.zig are
    // new; register them so their tests run under `zig build test`.
    _ = @import("core/provider_caps.zig");
    _ = @import("core/turn_control.zig");
    _ = @import("core/tool_name_map.zig");
    _ = @import("core/command_canonical.zig");
    _ = @import("core/bash_ast.zig");
    _ = @import("core/bash_input_framing.zig");
    _ = @import("core/command_prefix.zig");
    _ = @import("core/destructive_warning.zig");
    _ = @import("core/shell_snapshot.zig");
    _ = @import("core/shell_completion.zig");
    _ = @import("core/bash_segment_permission.zig");
    _ = @import("core/permission_decision.zig");
    _ = @import("core/dangerous_permissions.zig");
    _ = @import("core/permission_mode_cycle.zig");
    _ = @import("core/bash_mode_allow.zig");
    _ = @import("core/permission_reason.zig");
    _ = @import("core/permission_rule_string.zig");
    _ = @import("core/permission_rules.zig");
    _ = @import("core/shadow_detection.zig");
    _ = @import("core/denial_tracking.zig");
    _ = @import("core/path_safety.zig");
    _ = @import("core/path_utils.zig");
    _ = @import("core/hook_event.zig");
    _ = @import("core/mini_regex.zig");
    _ = @import("core/hook_matcher.zig");
    _ = @import("core/hook_io.zig");
    _ = @import("core/hook_config.zig");
    _ = @import("core/hook_exec_prompt.zig");
    _ = @import("core/hook_exec_http.zig");
    _ = @import("core/async_hook_registry.zig");
    _ = @import("core/hooks_snapshot.zig");
    _ = @import("core/session_hooks.zig");
    _ = @import("core/hook_events.zig");
    _ = @import("core/hooks_lifecycle_test.zig");
    _ = @import("core/hooks_runtime_wire_test.zig");
    _ = @import("core/settings_sources.zig");
    _ = @import("core/config_migrations.zig");
    _ = @import("core/mcp_name.zig");
    _ = @import("core/model_alias.zig");
    _ = @import("core/model_allowlist.zig");
    _ = @import("core/backoff.zig");
    // cancel_reason carries WHY a turn cancel fired (hard vs submit-interrupt)
    // alongside the bool cancel signal in providers/common.zig (parity phase
    // 22, agent-loop-deep task 22.1). Register so its tests run.
    _ = @import("core/cancel_reason.zig");
    // synthetic_tool_result formats the cancelled tool-result turn appended for
    // every emitted-but-unrun tool when a turn aborts mid-batch (parity phase
    // 22, agent-loop-deep task 22.2). Register so its tests run.
    _ = @import("core/synthetic_tool_result.zig");
    // max_output_escalation owns the 8k->64k single-shot cap escalation the loop
    // applies when a response is cut off by the max_output_tokens cap (parity
    // phase 22, agent-loop-deep task 22.4). Register so its tests run.
    _ = @import("core/max_output_escalation.zig");
    _ = @import("core/fallback_model.zig");
    _ = @import("core/budget_control.zig");
    _ = @import("core/reactive_compaction.zig");
    _ = @import("core/retry_after.zig");
    _ = @import("core/max_tokens_overflow.zig");
    _ = @import("core/custom_headers.zig");
    _ = @import("core/small_fast_model.zig");
    _ = @import("core/deprecation.zig");
    _ = @import("core/model_fallback_suggestion.zig");
    _ = @import("core/mcp_output_limits.zig");
    _ = @import("core/mcp_config.zig");
    _ = @import("core/mcp_env_expand.zig");
    _ = @import("core/mcp_policy.zig");
    _ = @import("core/mcp_approval.zig");
    _ = @import("core/mcp_blob_spill.zig");
    _ = @import("core/session_search.zig");
    _ = @import("core/agentic_session_search.zig");
    _ = @import("core/uuid.zig");
    _ = @import("core/task_list_id.zig");
    _ = @import("core/swarm_message.zig");
    _ = @import("core/teammate.zig");
    _ = @import("core/agent_isolation.zig");
    _ = @import("core/handoff_classifier.zig");
    _ = @import("core/coordinator_mode.zig");
    _ = @import("core/summary_cadence.zig");
    _ = @import("core/session_title.zig");
    _ = @import("core/session_export_md.zig");
    _ = @import("core/tips.zig");
    _ = @import("core/changelog.zig");
    _ = @import("core/autocomplete.zig");
    _ = @import("core/path_completion.zig");
    _ = @import("core/cc_stub_commands.zig");
    _ = @import("core/parity_command_coverage.zig");
    _ = @import("core/parity_tool_coverage.zig");
    _ = @import("core/wire_protocol.zig");
    _ = @import("core/retry_policy.zig");
    _ = @import("core/token_count.zig");
    _ = @import("core/streaming_chunks.zig");
    _ = @import("core/ink_layout.zig");
    _ = @import("core/ink_render.zig");
    _ = @import("core/ink_focus.zig");
    _ = @import("cli/ink_components/text.zig");
    _ = @import("cli/ink_components/box.zig");
    _ = @import("cli/ink_components/spinner.zig");
    _ = @import("cli/ink_components/newline.zig");
    _ = @import("cli/ink_components/spacer.zig");
    _ = @import("cli/ink_components/button.zig");
    _ = @import("cli/ink_components/link.zig");
    _ = @import("cli/ink_components/no_select.zig");
    _ = @import("cli/ink_components/raw_ansi.zig");
    _ = @import("cli/ink_components/scrollbox.zig");
    _ = @import("cli/ink_components/error_overview.zig");
    _ = @import("cli/ink_components/alternate_screen.zig");
    _ = @import("cli/ink_components/contexts.zig");
    _ = @import("cli/ink_components/batch6.zig");
    _ = @import("cli/ink_components/dialogs.zig");
    _ = @import("cli/ink_components/status_indicators.zig");
    _ = @import("cli/ink_components/user_messages.zig");
    _ = @import("cli/ink_components/assistant_messages.zig");
    _ = @import("cli/ink_components/tool_messages.zig");
    _ = @import("cli/ink_components/batch11.zig");
    _ = @import("cli/ink_components/batch12.zig");
    _ = @import("cli/ink_components/batch13.zig");
    _ = @import("cli/ink_components/batch14.zig");
    _ = @import("cli/ink_components/batch15.zig");
    _ = @import("cli/ink_components/batch16.zig");
    _ = @import("tools/todo_write.zig");
    _ = @import("tools/mcp_auth.zig");
    _ = @import("tools/repl_tool.zig");
    _ = @import("core/side_question.zig");
    _ = @import("core/removed_commands.zig");
    _ = @import("core/skill_types.zig");
    _ = @import("core/skill_listing.zig");
    _ = @import("core/skill_visibility.zig");
    _ = @import("core/skillify.zig");
    _ = @import("core/command_namespace.zig");
    _ = @import("core/cron.zig");
    _ = @import("core/kairos_lock.zig");
    _ = @import("core/runtime_state.zig");
    _ = @import("core/kairos_brief.zig");
    _ = @import("core/kairos_policy.zig");
    _ = @import("core/os_notify.zig");
    _ = @import("sdk/output.zig");
    _ = @import("sdk/messages.zig");
    _ = @import("sdk/structured_io.zig");
    _ = @import("sdk/control.zig");
    _ = @import("sdk/permission_prompt_tool.zig");
    _ = @import("sdk/stdout_guard.zig");
    _ = @import("sdk/streamlined.zig");
    _ = @import("sdk/headless.zig");
    _ = @import("kairos.zig");
    // session_registry is the cross-session live-process registry
    // (~/.zcode/sessions/registry/<pid>.json) behind `zcode ps`
    // (phase-26 daemon-background-02). Register so its tests run under
    // `zig build test`.
    _ = @import("core/session_registry.zig");
    // bg_cmds is the detached-session surface (`zcode ps`/`kill`/`logs` +
    // `--bg` spawn) over the registry (phase-26 daemon-background-01/09/10).
    _ = @import("bg_cmds.zig");
    // tmux_socket isolates agent-issued tmux onto a private `-L zcode-<pid>`
    // socket so `tmux kill-server` via Bash cannot touch the user's real
    // session (phase-26 daemon-background-06). Register so its tests run.
    _ = @import("core/tmux_socket.zig");
}

fn verboseLogsEnabled(opts: *const cli.CliOptions) bool {
    if (opts.verbose) return true;
    // Centralised in core/env.zig so this stays consistent with every
    // other env-flag check in the codebase. Bug-for-bug compatible
    // with the previous inlined version: "1", "true", "yes", "on"
    // (case-insensitive, trimmed) enable verbose logs; everything
    // else -- including the empty string and "0" -- disables them.
    return @import("core/env.zig").isEnvTruthy("ZCODE_VERBOSE");
}

/// Ignore SIGPIPE so writing to a closed pipe (e.g. `zcode ... | head -n 1`)
/// produces EPIPE that Zig turns into a clean write error, instead of
/// killing the process with an uncatchable signal and losing any
/// deferred cleanup (deinit of MCP clients, audit log, etc.). Called
/// once on startup.
fn ignoreSigPipe() void {
    if (@import("builtin").os.tag == .windows) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

/// SIGINT / SIGTERM handler that restores the terminal before exit.
/// The REPL puts the tty in raw mode and hides the cursor; if the
/// user hits Ctrl+C during a long model call, the default SIGINT
/// behavior kills the process with the cursor still hidden and the
/// scrollback painted with alt-screen bytes. This handler emits
/// the minimum ANSI restore sequence (show cursor, reset attributes,
/// leave alt screen) then exits with 128+signo per POSIX convention.
// Signature changed in Zig 0.16: Sigaction.handler_fn takes the
// platform-specific SIG enum, not c_int. Use the alias from posix.
fn restoreTermAndExit(signo: std.posix.SIG) callconv(.c) void {
    if (@import("builtin").os.tag == .windows) {
        std.process.exit(128);
    }
    // Only emit ANSI restore when stderr is a real terminal. Emitting
    // escape codes to a CI log or file would pollute the record with
    // garbage that looks like output corruption on re-read.
    // 0.16 dropped std.posix.isatty; call libc directly (we link libc).
    if (std.c.isatty(std.posix.STDERR_FILENO) != 0) {
        const restore = "\x1b[?25h" ++ // show cursor
            "\x1b[0m" ++ // reset attributes
            "\x1b[?1049l"; // leave alt screen
        _ = std.c.write(std.posix.STDERR_FILENO, restore.ptr, restore.len);
    }
    // Exit via the default signal action would be cleaner (preserves
    // WIFSIGNALED for parent shells), but that requires un-installing
    // the handler and re-raising - enough complexity that a direct
    // exit with the conventional code is preferable here.
    std.process.exit(@intCast(128 + @as(u8, @intCast(@intFromEnum(signo) & 0xff))));
}

fn installInterruptHandlers() void {
    if (@import("builtin").os.tag == .windows) return;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = restoreTermAndExit },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    // Also handle SIGHUP. The default action is "terminate without
    // running our cleanup," which means raw-mode tty state, the
    // alt-screen, and the hidden cursor never get reset when the
    // user closes the terminal emulator, drops an SSH connection,
    // or fires `kill -HUP <pid>`. The next shell on the same TTY
    // then inherits a broken termcap and the user has to type
    // `stty sane; reset` blind. Treating SIGHUP like SIGTERM (clean
    // up and exit) is the normal convention for interactive REPLs.
    std.posix.sigaction(std.posix.SIG.HUP, &act, null);
    // SIGQUIT (Ctrl+\): defaults to "terminate with core dump."
    // RLIMIT_CORE=0 (set in applyParentLimits) suppresses the core
    // dump, but the process still exits without running cleanup --
    // same broken-tty fallout as the SIGHUP case fixed in pass 97.
    // Route to restoreTermAndExit so a Ctrl+\ on a stuck REPL
    // leaves the terminal in a usable state.
    std.posix.sigaction(std.posix.SIG.QUIT, &act, null);
}

/// settings-03 approval gate. Runs the dangerous-key prompt for managed config
/// files when warranted. Kept thin: all classification + fingerprint logic
/// lives in the testable core/managed_security.zig; this function owns only the
/// interactivity check, the prompt I/O, and the exit(1) on reject.
fn maybeGateManagedDangerousSettings(
    allocator: std.mem.Allocator,
    loaded_cfg: *config_mod.LoadedConfig,
    opts: *const cli.CliOptions,
) void {
    const managed_security = @import("core/managed_security.zig");
    const dangerous = if (loaded_cfg.managed_dangerous) |*d| d else return;
    if (!dangerous.hasDangerous()) return;

    // Cache the last-approved fingerprint under the user state dir so an
    // unchanged managed file does not re-prompt every launch.
    const cache_path = std.fs.path.join(allocator, &.{ loaded_cfg.paths.zcode_home, "managed_approval.fingerprint" }) catch return;
    defer allocator.free(cache_path);

    const cached = managed_security.readCachedFingerprint(allocator, cache_path) catch null;
    defer if (cached) |c| allocator.free(c);

    const changed = managed_security.hasChanged(allocator, cached, dangerous) catch true;
    if (!changed) return;

    // Interactivity: prompt only for the interactive REPL on a real TTY, and
    // never under --quiet / --json (those opted into a clean, scriptable
    // stream). Anything else proceeds without prompting (fail-open for
    // AVAILABILITY in automation, matching the reference's non-interactive
    // no_check_needed path).
    const is_interactive = opts.command == .repl and
        !opts.quiet and
        !opts.json and
        std.c.isatty(std.posix.STDERR_FILENO) != 0 and
        std.c.isatty(std.Io.File.stdin().handle) != 0;
    if (!is_interactive) return;

    const stderr = std_io.stderrWriter();
    stderr.writeAll(
        "zcode: a managed (admin-pushed) config file contains settings that can run\n" ++
            "       shell commands or change inference routing. Review before applying:\n",
    ) catch {};
    const names = dangerous.formatDangerousList(allocator) catch {
        // If we cannot even format the list, fail closed: do not silently
        // apply dangerous managed keys.
        stderr.writeAll("zcode: managed settings could not be summarized; refusing to apply. Exiting.\n") catch {};
        std.process.exit(1);
    };
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
    for (names) |n| {
        stderr.print("       - {s}\n", .{n}) catch {};
    }
    stderr.writeAll("Apply these managed settings? [y/N] ") catch {};

    const answer = std_io.stdinReader().readUntilDelimiterOrEofAlloc(allocator, '\n', 256) catch null;
    const approved = blk: {
        const line = answer orelse break :blk false;
        const t = std.mem.trim(u8, line, " \t\r\n");
        break :blk std.ascii.eqlIgnoreCase(t, "y") or std.ascii.eqlIgnoreCase(t, "yes");
    };
    if (answer) |a| allocator.free(a);

    if (!approved) {
        stderr.writeAll("zcode: managed settings rejected. Exiting.\n") catch {};
        std.process.exit(1);
    }

    // Approved: persist the new fingerprint so this exact set does not
    // re-prompt next launch.
    const fp = dangerous.fingerprint(allocator) catch return;
    defer allocator.free(fp);
    managed_security.writeCachedFingerprint(allocator, cache_path, fp) catch {};
}

pub fn main(init: std.process.Init) !void {
    // Make io + gpa available to the core shims (clock, rng, std_io)
    // and to any module-level helper that doesn't yet thread io
    // explicitly. Stage 4 of the 0.16 migration retires this singleton.
    rt.install(init);

    ignoreSigPipe();
    installInterruptHandlers();
    // Cap fork-bomb / FD-flood / core-dump exposure across the whole
    // process tree (parent zcode + every spawned tool). Best-effort:
    // failures are swallowed inside applyParentLimits since hosts
    // with stricter pre-existing rlimits will simply keep theirs.
    @import("core/resource_limits.zig").applyParentLimits();

    defer tool_dispatch.deinitCronStore();
    const allocator = init.gpa;

    // Convert init.minimal.args.vector ([*:0]const u8 sentinel ptrs)
    // into []const []const u8 expected by cli.parse and downstream
    // code. Init owns the underlying storage; the slice array we
    // allocate here is freed by the arena on exit anyway, but be
    // tidy and free it explicitly.
    const argv = blk: {
        const buf = try allocator.alloc([]const u8, init.minimal.args.vector.len);
        for (init.minimal.args.vector, 0..) |arg_ptr, i| buf[i] = std.mem.span(arg_ptr);
        break :blk buf;
    };
    defer allocator.free(argv);
    rt.setArgv(argv);

    var opts = cli.parse(allocator, argv[1..]) catch |err| {
        // FlagFileUnreadable: the parser already printed a targeted
        // error message to stderr (file not found, permission denied,
        // etc.) - exit without adding a generic second line or the
        // full usage dump.
        if (err == error.FlagFileUnreadable) std.process.exit(2);
        // UsageErrorReported: the parser printed a specific, per-
        // subcommand "missing <arg>. Usage: ..." line. Exit silently
        // so the user isn't double-messaged with a generic "missing
        // subcommand" line plus the full global help dump.
        if (err == error.UsageErrorReported) std.process.exit(2);
        // FlagValueTooLarge: the parser already emitted a targeted
        // "value is N bytes, exceeds the 1 MiB cap" line pointing
        // the user at --append-system-prompt-file. Exit 2 silently.
        if (err == error.FlagValueTooLarge) std.process.exit(2);
        const stderr = std_io.stderrWriter();
        const detail: []const u8 = switch (err) {
            error.UnknownFlag => "unrecognized flag. Run 'zcode --help' for available options",
            error.UnknownSubcommand, error.UnknownCommand => "unrecognized subcommand. Run 'zcode --help' for available commands",
            error.MissingSubcommand => "missing subcommand. Run 'zcode --help' for usage",
            error.MissingFlagValue => "flag requires a value",
            error.MissingPrompt => "missing prompt argument. Run 'zcode --help' for usage",
            error.Overflow, error.InvalidCharacter => "invalid numeric value for flag",
            error.InvalidFlagValue => "flag value is out of range (zero or non-sensical). Use a positive integer.",
            else => @errorName(err),
        };
        try stderr.print("error: {s}\n", .{detail});
        try cli.printUsage(stderr);
        std.process.exit(2);
    };
    defer opts.deinit(allocator);

    // Reject semantically-contradictory flag pairs up front so a
    // typo doesn't silently adopt one side and leave the user
    // wondering which won. Quieter alternative modes (--accessible
    // implies --no-color) stay compatible because they're additive,
    // not contradictory.
    if (opts.verbose and opts.quiet) {
        try std_io.stderrWriter().writeAll(
            "error: --verbose and --quiet are contradictory; pick one (or use --log-level=<debug|info|warn|error>).\n",
        );
        std.process.exit(2);
    }
    if (opts.yolo and opts.strict) {
        try std_io.stderrWriter().writeAll(
            "error: --yolo and --strict are contradictory; --yolo auto-approves everything while --strict refuses anything not explicitly allowed.\n",
        );
        std.process.exit(2);
    }
    if (opts.approve_high and opts.strict) {
        try std_io.stderrWriter().writeAll(
            "error: --approve-high and --strict are contradictory; --approve-high auto-approves high-risk tools while --strict refuses them.\n",
        );
        std.process.exit(2);
    }

    // Apply log-runtime overrides BEFORE any std.log emission so the
    // first warn/info honors the operator's preference. Invalid
    // values print a targeted error and exit 2 so typos surface
    // immediately instead of being silently ignored.
    if (opts.log_level) |lvl| {
        log_runtime.setLevelFromString(lvl) catch {
            try std_io.stderrWriter().print(
                "error: invalid --log-level '{s}'. Expected one of: debug, info, warn, error.\n",
                .{lvl},
            );
            std.process.exit(2);
        };
    }
    if (opts.log_format) |fmt| {
        log_runtime.setFormatFromString(fmt) catch {
            try std_io.stderrWriter().print(
                "error: invalid --log-format '{s}'. Expected one of: text, json.\n",
                .{fmt},
            );
            std.process.exit(2);
        };
    }
    // In verbose mode, drop the level floor to info so the user sees
    // the diagnostic info lines that are normally suppressed under
    // the default warn threshold.
    if (opts.verbose and opts.log_level == null) {
        log_runtime.setLevelFromString("info") catch {};
    }
    // Under --quiet, bump the floor to error so warn lines stop
    // cluttering machine-readable output pipelines.
    if (opts.quiet and opts.log_level == null) {
        log_runtime.setLevelFromString("error") catch {};
    }
    // Silence the plaintext-api-key warning in machine-readable or
    // explicitly-quiet modes. The warning is security-relevant, so we
    // still emit it by default; operators who asked for --quiet /
    // --json / --log-level=error have opted into a clean stderr.
    {
        const should_silence = opts.quiet or opts.json or blk: {
            if (opts.log_level) |lvl| {
                break :blk std.ascii.eqlIgnoreCase(lvl, "error") or std.ascii.eqlIgnoreCase(lvl, "err");
            }
            break :blk false;
        };
        if (should_silence) @import("core/config_parse.zig").silencePlaintextWarning();
    }

    if (opts.command == .help) {
        try cli.printUsage(std_io.stdoutWriter());
        return;
    }

    if (opts.command == .version) {
        try std_io.stdoutWriter().print("zcode {s}\n", .{build_options.app_version});
        return;
    }

    if (opts.command == .list_env) {
        const env_registry = @import("core/env_registry.zig");
        const table = try env_registry.renderTable(allocator);
        defer allocator.free(table);
        try std_io.stdoutWriter().writeAll(table);
        return;
    }

    // `config path` resolves from paths.resolve + env, so it must
    // work even when config.toml is broken (that's precisely when
    // operators reach for it). Fast-path it here.
    if (opts.command == .config_path) {
        try printConfigPaths(allocator, std_io.stdoutWriter());
        return;
    }

    const cwd = config_mod.resolveWorkingDirectory(allocator, &opts) catch |err| {
        // resolveWorkingDirectory printed its own targeted stderr
        // message for InvalidCwd; exit 2 without piling on.
        if (err == error.InvalidCwd) std.process.exit(2);
        return err;
    };
    defer allocator.free(cwd);

    // Idempotent startup pass that renames/relocates deprecated config keys
    // before the config is parsed, so migrated keys are picked up by load().
    // Never fails startup: each migration logs-and-skips on error.
    @import("core/config_migrations.zig").runAll(allocator, cwd);

    var loaded_cfg = config_mod.load(allocator, cwd, &opts) catch |err| {
        // FileTooBig: config_parse already emitted a targeted line
        // naming the offending file and the 1 MiB limit. Exit silently.
        if (err == error.FileTooBig) std.process.exit(2);
        const stderr = std_io.stderrWriter();
        // AccessDenied: the generic "Delete the file to start fresh"
        // hint is actively dangerous (the user's real config is
        // unreadable by zcode's effective uid, not corrupt) and the
        // "syntax errors" hint is irrelevant. Give a targeted hint
        // naming the permission issue instead.
        if (err == error.AccessDenied) {
            try stderr.writeAll(
                "error: failed to load config: permission denied reading config file.\n" ++
                    "  - Check the file's mode and owner; zcode does not elevate.\n" ++
                    "  - Run `zcode config path` to see the candidate paths.\n",
            );
            std.process.exit(2);
        }
        // NotDir: a component of a candidate config path was not a
        // directory (e.g. $HOME=/dev/null in a container misconfig;
        // or ~/.zcode is a regular file blocking the config
        // subdirectory). Same "Delete the file" problem as the
        // other non-syntax errors above.
        if (err == error.NotDir) {
            try stderr.writeAll(
                "error: failed to load config: a path component is not a directory.\n" ++
                    "  - Run `zcode config path` to see the candidate paths.\n" ++
                    "  - Check whether $HOME / $XDG_CONFIG_HOME points at a directory (common container misconfig: HOME=/dev/null).\n",
            );
            std.process.exit(2);
        }
        // Overflow / InvalidCharacter: config_parse already emitted
        // a targeted `zcode: config error: `<key> = <value>`...`
        // line naming the offending key and the valid range.
        // Repeating the generic "Check for syntax errors / Delete
        // the file" hints here is redundant at best and dangerous at
        // worst (the user's real config has ONE bad numeric value,
        // not corruption). Exit 2 silently.
        if (err == error.Overflow or err == error.InvalidCharacter) std.process.exit(2);
        try stderr.print("error: failed to load config: {s}\n", .{@errorName(err)});
        try stderr.writeAll(
            "  - Check ~/.zcode/config.toml and ./.zcode/config.toml for syntax errors\n" ++
                "  - Run with --verbose for details\n" ++
                "  - Delete the file to start fresh; defaults will be regenerated\n",
        );
        std.process.exit(2);
    };
    defer loaded_cfg.deinit(allocator);
    loaded_cfg.config.validate() catch |err| {
        const stderr = std_io.stderrWriter();
        // Surface per-error hints that name the valid set. Before this,
        // `--sandbox nope` printed
        //   error: invalid configuration: InvalidSandboxProfile
        // and left the user to grep source for the known values.
        switch (err) {
            error.InvalidSandboxProfile => try stderr.print(
                "error: invalid --sandbox '{s}'. Expected one of: read-only, workspace-write, no-network, danger-full-access, none.\n",
                .{loaded_cfg.config.sandbox},
            ),
            error.InvalidApprovalMode => try stderr.print(
                "error: invalid --approval-mode '{s}'. Expected one of: tiered-auto, manual, strict.\n",
                .{loaded_cfg.config.approval_mode},
            ),
            error.InvalidProvider => try stderr.print(
                "error: invalid provider '{s}'. Expected one of: openai, anthropic, gemini, deepseek, groq, openrouter, azure, azure-openai, local, ollama, openai-compatible, mock.\n",
                .{loaded_cfg.config.default_provider},
            ),
            error.InvalidPreprocessorProvider => try stderr.print(
                "error: invalid --preprocessor-provider '{s}'. Expected one of: openai, anthropic, gemini, deepseek, groq, openrouter, azure, azure-openai, local, ollama, openai-compatible, mock.\n",
                .{loaded_cfg.config.preprocessor_provider},
            ),
            error.InvalidPreprocessorModel => try stderr.writeAll(
                "error: invalid configuration: --preprocessor is enabled but preprocessor_model is empty.\n  - Pass --preprocessor-model <id> or set `preprocessor_model` in config.toml.\n",
            ),
            error.InvalidModel => try stderr.writeAll(
                "error: invalid configuration: default_model is empty.\n  - Set a model via --model <id> or `default_model = \"...\"` in config.toml.\n",
            ),
            error.InvalidModelContextWindow => try stderr.writeAll(
                "error: invalid configuration: model_context_window must be > 0.\n  - Set a positive integer in config.toml (typical: 128000 or 200000).\n",
            ),
            error.InvalidReservedOutput, error.InvalidReservedReasoning => try stderr.writeAll(
                "error: invalid configuration: reserved_output_tokens + reserved_reasoning_tokens must not exceed model_context_window.\n  - Lower the reserved-* values in config.toml or raise model_context_window.\n",
            ),
            error.InvalidUiDensity => try stderr.print(
                "error: invalid ui_density '{s}'. Expected one of: full, clean.\n",
                .{loaded_cfg.config.ui_density},
            ),
            error.InvalidApiProfile => try stderr.print(
                "error: invalid api_profile '{s}'. Expected one of: read-only, editor, full.\n",
                .{loaded_cfg.config.api_profile},
            ),
            error.InvalidApiRole => try stderr.print(
                "error: invalid api_role '{s}'. Expected one of: none, viewer, auditor, editor, owner.\n",
                .{loaded_cfg.config.api_role},
            ),
            error.InvalidApiOidcConfig => try stderr.writeAll(
                "error: invalid API OIDC configuration: set api_oidc_issuer + api_oidc_audience plus api_oidc_hs256_secret or api_oidc_jwks_json/api_oidc_jwks_file/api_oidc_jwks_url.\n",
            ),
            error.InvalidApiAuthConfig => try stderr.writeAll(
                "error: invalid API auth configuration: api_auth_required=true needs api_bearer_token or complete OIDC settings (HS256 secret or RS256 JWKS json/file/url).\n",
            ),
            error.InvalidEgressAllowlist => try stderr.writeAll(
                "error: invalid egress_allowlist. Use comma-separated hosts such as api.openai.com,*.anthropic.com; do not include schemes or paths.\n",
            ),
            error.InvalidEgressDenylist => try stderr.writeAll(
                "error: invalid egress_denylist. Use comma-separated hosts such as evil.com,*.bad.example; do not include schemes or paths.\n",
            ),
            error.InvalidTheme => try stderr.print(
                "error: invalid ui_theme '{s}'. Check `src/core/ui_theme.zig` parseThemeSetting for the accepted set.\n",
                .{loaded_cfg.config.ui_theme},
            ),
            else => {
                try stderr.print("error: invalid configuration: {s}\n", .{@errorName(err)});
                try stderr.writeAll(
                    "  - See 'zcode --help' for valid CLI flags\n" ++
                        "  - Review ~/.zcode/config.toml and ./.zcode/config.toml\n" ++
                        "  - Common causes: reserved_output_tokens + reserved_reasoning_tokens exceeds model_context_window; unknown provider/sandbox/approval_mode values\n",
                );
            },
        }
        std.process.exit(2);
    };

    // settings-03: before applying managed-file keys for real, gate any
    // dangerous ones (command-helper keys, non-safe env vars, a [hooks]
    // section) behind an accept/reject prompt -- but only when interactive and
    // only when the dangerous set has changed vs the last-approved snapshot. On
    // reject we exit(1). Non-interactive runs skip the prompt (so automation is
    // never blocked), matching the reference trust-dialog behavior.
    maybeGateManagedDangerousSettings(allocator, &loaded_cfg, &opts);

    @import("core/egress.zig").configureRuntimePolicy(
        loaded_cfg.config.egress_allowlist,
        loaded_cfg.config.egress_denylist,
        loaded_cfg.config.egress_allow_private_network_plaintext,
    );

    if (loaded_cfg.config.control_plane_policy_sync) {
        _ = try control_plane.syncPolicyBundle(
            allocator,
            loaded_cfg.config.control_plane_url,
            loaded_cfg.config.control_plane_token,
            loaded_cfg.paths.policy_path,
            loaded_cfg.config.control_plane_policy_verify_hash,
        );
    }

    var policy = try policy_mod.Policy.init(allocator);
    defer policy.deinit();
    _ = file_integrity.verifySha256Sidecar(allocator, loaded_cfg.paths.policy_path) catch |err| {
        const stderr = std_io.stderrWriter();
        try stderr.print("error: policy integrity check failed for {s}: {s}\n", .{ loaded_cfg.paths.policy_path, @errorName(err) });
        try stderr.writeAll("  - Fix the .sha256 sidecar or remove it if this policy is intentionally unsigned.\n");
        std.process.exit(2);
    };
    _ = policy.loadFromFile(loaded_cfg.paths.policy_path) catch |err| {
        try printPolicyErrorAndExit(err, loaded_cfg.paths.policy_path);
        unreachable;
    };
    policy.validate() catch |err| {
        try printPolicyErrorAndExit(err, loaded_cfg.paths.policy_path);
        unreachable;
    };

    var audit = logger_mod.AuditLogger.initWithRetention(allocator, loaded_cfg.paths.logs_dir, loaded_cfg.config.audit_retention_days) catch |err| {
        const stderr = std_io.stderrWriter();
        try stderr.print("error: audit logger failed to start: {s}\n", .{@errorName(err)});
        try stderr.writeAll(
            "  - The audit log HMAC key could not be loaded or created.\n" ++
                "  - Check permissions on the logs directory (shown above).\n" ++
                "  - Delete hmac.key to force regeneration, or chmod it to 0600.\n" ++
                "  - zcode refuses to run with an insecure (zero) integrity key.\n",
        );
        std.process.exit(2);
    };
    defer audit.deinit();
    audit.setRedactPromptBodies(loaded_cfg.config.privacy_redact_prompt_bodies);

    var store = session_store.Store.init(allocator, loaded_cfg.paths.sessions_dir, loaded_cfg.config.session_encryption_enabled) catch |err| switch (err) {
        error.SessionKeyPersistFailed => {
            const stderr = std_io.stderrWriter();
            try stderr.writeAll(
                "error: cannot persist the session encryption key and cannot continue with encryption enabled.\n" ++
                    "  - Install/start an OS keychain backend (Keychain on macOS, libsecret on Linux),\n" ++
                    "  - or export ZCODE_SESSION_KEY=hex:<64 hex chars> to supply a key explicitly,\n" ++
                    "  - or set session_encryption_enabled = false in ~/.zcode/config.toml.\n",
            );
            std.process.exit(2);
        },
        else => return err,
    };
    defer store.deinit();

    // Retire stale .jsonl session files based on session_retention_days
    // (default 0 = no-op). Mirrors how core/logger.zig runs cleanupOldLogs
    // at AuditLogger init -- the storage primitive is in src/session/
    // store.zig cleanupOldSessions and the wire-up happens here so the
    // sweep runs once per process startup before any user-visible work.
    // Failures are logged and swallowed so a broken sweep can't block
    // session storage from working.
    if (loaded_cfg.config.session_retention_days > 0) {
        const cleanup_result = store.cleanupOldSessions(loaded_cfg.config.session_retention_days) catch |err| blk: {
            std.log.warn("session retention sweep failed: {s}", .{@errorName(err)});
            break :blk session_store.Store.CleanupResult{};
        };
        if (verboseLogsEnabled(&opts) and (cleanup_result.deleted > 0 or cleanup_result.errors > 0)) {
            std.log.info(
                "session retention: deleted={d} errors={d} retention_days={d}",
                .{ cleanup_result.deleted, cleanup_result.errors, loaded_cfg.config.session_retention_days },
            );
        }
    }

    var mcp = try mcp_client.Client.init(allocator, loaded_cfg.paths.mcp_registry_path);
    defer mcp.deinit();
    // Enable structured scoped-config loading so servers declared in a project
    // `.mcp.json` (with command/args/env or url/headers/headersHelper) actually
    // drive live connections, merged with the legacy `mcp add` registry. Unit
    // tests never call this, so they stay hermetic.
    mcp.enableScopedConfig();

    // Chrome browser bridge (WebSocket server for lchrome extension)
    var browser_bridge = browser_bridge_mod.BrowserBridge.init(allocator, loaded_cfg.config.browser_bridge_port);
    var browser_bridge_started = false;
    if (loaded_cfg.config.browser_bridge_enabled) {
        browser_bridge.start() catch |err| {
            std.log.warn("Chrome bridge: failed to start: {s}", .{@errorName(err)});
        };
        if (browser_bridge.server != null) {
            browser_bridge_started = true;
            if (verboseLogsEnabled(&opts)) {
                std.log.info("Chrome bridge: listening on port {d}", .{loaded_cfg.config.browser_bridge_port});
            }
        }
    }
    defer if (browser_bridge_started) browser_bridge.deinit();

    const browser_ptr: ?*browser_bridge_mod.BrowserBridge = if (browser_bridge_started) &browser_bridge else null;

    dispatch(
        allocator,
        &opts,
        cwd,
        &loaded_cfg.config,
        &policy,
        &audit,
        &store,
        &mcp,
        browser_ptr,
    ) catch |err| {
        // AgentNotFound: activateAgentByNameStrict already printed
        // a targeted stderr line naming the missing agent; exit 2
        // without dumping the (provider=..., model=...) envelope
        // since it's a CLI argument problem, not a provider crash.
        if (err == error.AgentNotFound) std.process.exit(2);
        // UnknownOutputStyle: AgentRuntime.init already printed a
        // targeted stderr line. Same reasoning as AgentNotFound --
        // it is a CLI argument problem.
        if (err == error.UnknownOutputStyle) std.process.exit(2);
        // A closed stdout pipe (`zcode prompt inspect | head`) is not
        // a model/provider failure. Treat it like standard Unix tools:
        // stop writing and exit cleanly without the provider envelope.
        if (err == error.BrokenPipe) std.process.exit(0);
        const common = @import("providers/common.zig");
        const stderr = std_io.stderrWriter();
        const provider = loaded_cfg.config.default_provider;
        const model = loaded_cfg.config.default_model;
        const description = common.describeProviderError(err);
        try stderr.print("\nerror: {s} (provider={s}, model={s})\n\n{s}\n", .{ @errorName(err), provider, model, description });
        std.process.exit(1);
    };
}

fn dispatch(
    allocator: std.mem.Allocator,
    opts: *cli.CliOptions,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
) !void {
    const stdout = std_io.stdoutWriter();
    const yolo_mode = opts.yolo;
    const auto_approve_high = opts.approve_high or yolo_mode;

    // phase-26 daemon-background-01: `--bg`/`--background` detaches a
    // session-running command instead of executing it in this process. Only
    // the run-bearing commands (REPL + one-shot run/exec) are detachable; for
    // anything else the flag is a no-op. The child re-invokes zcode without
    // `--bg`, self-registers with kind=bg, and captures its output to a log.
    if (opts.bg and (opts.command == .repl or opts.command == .run or opts.command == .exec)) {
        try bg_cmds.spawnBackground(allocator, rt.argv, cwd, stdout);
        return;
    }

    switch (opts.command) {
        .version => {
            try stdout.print("zcode {s}\n", .{build_options.app_version});
        },
        .repl => try session_mgmt.runInteractive(allocator, cwd, cfg, policy, audit, store, mcp, browser, auto_approve_high, opts.strict, yolo_mode, null, opts.agent, opts.name),
        .run => {
            // sdk-headless: when an SDK transport is selected (--output-format
            // json|stream-json, or --input-format stream-json) the run is
            // routed into the SDK serializers / control protocol instead of the
            // legacy text/encodeExecJson rendering. Plain `run`/`--print` with
            // no transport flags keeps the legacy path below.
            if (try runHeadlessDispatch(allocator, opts, cwd, cfg, policy, audit, store, mcp, browser, auto_approve_high, yolo_mode)) return;
            const run_prompt = opts.prompt orelse {
                try std_io.stderrWriter().writeAll(
                    "error: --print without a prompt requires --input-format stream-json (the prompt arrives over stdin).\n",
                );
                std.process.exit(2);
            };
            const one_shot = try session_mgmt.runOneShot(allocator, cwd, cfg, policy, audit, store, mcp, browser, run_prompt, false, auto_approve_high, opts.strict, yolo_mode, opts.agent);
            defer allocator.free(one_shot.body);
            // Clean tool-call envelopes out of the one-shot body so
            // `zcode run "..."` matches the REPL's rendering discipline
            // (pass 12). Leaves ordinary prose intact; returns empty
            // when the model emitted only protocol bytes, which we
            // surface as "(no narration)" so the user gets a signal
            // the turn completed but had nothing text-worthy to say.
            const assistant_render = @import("core/assistant_render.zig");
            const cleaned = try assistant_render.cleanAssistantText(allocator, one_shot.body);
            defer allocator.free(cleaned);
            const rendered = if (cleaned.len == 0) "(no narration; see tool output above)" else cleaned;
            const repl_markdown = @import("cli/repl_markdown.zig");
            if (std.c.isatty(std.Io.File.stdout().handle) != 0) {
                try repl_markdown.writeStyledText(stdout, rendered, .{
                    .color_enabled = true,
                    .highlight_code_blocks = true,
                    .highlight_links = true,
                    .highlight_paths = true,
                    .color_lists = true,
                });
            } else {
                try stdout.writeAll(rendered);
            }
            if (!std.mem.endsWith(u8, rendered, "\n")) try stdout.writeByte('\n');
            if (one_shot.strict_violation) {
                const stderr = std_io.stderrWriter();
                try stderr.writeAll(
                    "error: strict mode violation. The run emitted output that violated the strict-mode contract.\n" ++
                        "  - Re-run without --strict to see the raw response, or\n" ++
                        "  - Tighten the prompt so the model stays within the strict-mode schema.\n",
                );
                std.process.exit(2);
            }
        },
        .exec => {
            // sdk-headless: same transport routing as `.run`. With a transport
            // flag, `exec` emits SDK-shaped messages; without one it keeps the
            // legacy encodeExecJson blob below.
            if (try runHeadlessDispatch(allocator, opts, cwd, cfg, policy, audit, store, mcp, browser, auto_approve_high, yolo_mode)) return;
            const exec_prompt = opts.prompt orelse {
                try std_io.stderrWriter().writeAll(
                    "error: exec without a prompt requires --input-format stream-json (the prompt arrives over stdin).\n",
                );
                std.process.exit(2);
            };
            const one_shot = try session_mgmt.runOneShot(allocator, cwd, cfg, policy, audit, store, mcp, browser, exec_prompt, true, auto_approve_high, opts.strict, yolo_mode, opts.agent);
            defer allocator.free(one_shot.body);
            try stdout.writeAll(one_shot.body);
            if (!std.mem.endsWith(u8, one_shot.body, "\n")) try stdout.writeByte('\n');
            if (one_shot.strict_violation) {
                const stderr = std_io.stderrWriter();
                try stderr.writeAll(
                    "error: strict mode violation. The run emitted output that violated the strict-mode contract.\n" ++
                        "  - Re-run without --strict to see the raw response, or\n" ++
                        "  - Tighten the prompt so the model stays within the strict-mode schema.\n",
                );
                std.process.exit(2);
            }
        },
        .models_list => try session_mgmt.cmdModelsList(allocator, cfg, stdout),
        .models_test => blk: {
            const target_model = opts.subject orelse cfg.default_model;
            session_mgmt.cmdModelsTest(allocator, cfg, target_model, stdout) catch |err| switch (err) {
                // `models test` takes its own <model> argument, so the
                // generic "error: ... (provider=local, model=<default>)"
                // envelope that main.zig uses for the agent path is
                // actively misleading here -- it prints the default
                // model from cfg rather than the one the operator
                // asked to probe. Give a handler-specific line that
                // names the target model + provider.
                error.ModelNotFound => {
                    const err_w = std_io.stderrWriter();
                    try err_w.print(
                        "error: models test: model '{s}' not found on provider '{s}'.\n  - For Ollama: run `ollama pull {s}` to download it first\n  - For cloud APIs: check that the model id is correct\n  - Run `zcode models list` for available models\n",
                        .{ target_model, cfg.default_provider, target_model },
                    );
                    // 3P fallback suggestion: a brand-new model id can 404 on a
                    // third-party host that has not stocked it yet. Point the
                    // operator at the immediately-preceding version. First-party
                    // (anthropic) always has the newest model, so this is null
                    // there and the extra line is skipped.
                    if (model_fallback_suggestion.suggest(target_model, cfg.default_provider)) |fallback| {
                        try err_w.print(
                            "  - Try '{s}' instead (the previous version), or run `zcode models list`\n",
                            .{fallback},
                        );
                    }
                    std.process.exit(1);
                },
                error.AuthenticationFailed => {
                    try std_io.stderrWriter().print(
                        "error: models test: authentication failed for provider '{s}'.\n  - Check your API key env var (OPENAI_API_KEY, ANTHROPIC_API_KEY, ...)\n  - Run `zcode providers status` to see which provider is active\n",
                        .{cfg.default_provider},
                    );
                    std.process.exit(1);
                },
                else => return err,
            };
            break :blk;
        },
        .agents_list => session_mgmt.cmdAgentsList(allocator, cwd, stdout) catch |err| switch (err) {
            error.InvalidAgentDefinition => std.process.exit(1),
            else => return err,
        },
        .agents_show => session_mgmt.cmdAgentsShow(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.InvalidAgentDefinition => std.process.exit(1),
            else => return err,
        },
        .hooks_list => try session_mgmt.cmdHooksList(allocator, cwd, stdout),
        .marketplace_sources => try session_mgmt.cmdMarketplaceSources(allocator, stdout),
        .marketplace_add => try session_mgmt.cmdMarketplaceAdd(allocator, opts.subject, opts.prompt, stdout),
        .marketplace_remove => session_mgmt.cmdMarketplaceRemove(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.MarketplaceEntryNotFound => std.process.exit(1),
            else => return err,
        },
        .marketplace_refresh => try session_mgmt.cmdMarketplaceRefresh(allocator, opts.subject, stdout),
        .plugins_list => session_mgmt.cmdPluginsList(allocator, cwd, stdout) catch |err| switch (err) {
            error.InvalidPluginManifest => std.process.exit(1),
            else => return err,
        },
        .plugins_show => session_mgmt.cmdPluginsShow(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.PluginNotFound, error.InvalidPluginManifest => std.process.exit(1),
            else => return err,
        },
        .plugins_marketplace => try session_mgmt.cmdPluginsMarketplace(allocator, cwd, opts.subject, stdout),
        .plugins_install => try session_mgmt.cmdPluginsInstall(allocator, cwd, opts.subject, stdout),
        .plugins_uninstall => session_mgmt.cmdPluginsUninstall(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.EntryNotInstalled => std.process.exit(1),
            else => return err,
        },
        .plugins_update => session_mgmt.cmdPluginsUpdate(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.EntryNotInstalled => std.process.exit(1),
            else => return err,
        },
        .plugins_enable => session_mgmt.cmdPluginsEnable(allocator, cwd, opts.subject, opts.scope, stdout) catch |err| switch (err) {
            error.InvalidScope => std.process.exit(1),
            else => return err,
        },
        .plugins_disable => session_mgmt.cmdPluginsDisable(allocator, cwd, opts.subject, opts.scope, stdout) catch |err| switch (err) {
            error.InvalidScope => std.process.exit(1),
            else => return err,
        },
        .plugins_disable_all => session_mgmt.cmdPluginsDisableAll(allocator, cwd, opts.scope, stdout) catch |err| switch (err) {
            error.InvalidScope => std.process.exit(1),
            else => return err,
        },
        .commands_list => try session_mgmt.cmdCommandsList(allocator, cwd, stdout),
        .commands_show => session_mgmt.cmdCommandsShow(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.CommandNotFound => std.process.exit(1),
            else => return err,
        },
        .commands_run => session_mgmt.cmdCommandsRun(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.subject, opts.prompt, stdout, auto_approve_high, opts.strict, yolo_mode, opts.agent) catch |err| switch (err) {
            error.CommandNotFound => std.process.exit(1),
            else => return err,
        },
        .commands_marketplace => try session_mgmt.cmdCommandsMarketplace(allocator, cwd, opts.subject, stdout),
        .commands_install => try session_mgmt.cmdCommandsInstall(allocator, cwd, opts.subject, stdout),
        .commands_uninstall => session_mgmt.cmdCommandsUninstall(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.EntryNotInstalled => std.process.exit(1),
            else => return err,
        },
        .commands_update => session_mgmt.cmdCommandsUpdate(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.EntryNotInstalled => std.process.exit(1),
            else => return err,
        },
        .skills_list => try session_mgmt.cmdSkillsList(allocator, cwd, stdout),
        .skills_show => try session_mgmt.cmdSkillsShow(allocator, cwd, opts.subject, stdout),
        .skills_run => try session_mgmt.cmdSkillsRun(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.subject, opts.prompt, stdout, auto_approve_high, opts.strict, yolo_mode, opts.agent),
        .trust_status => session_mgmt.cmdTrustStatus(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.InvalidTrustStore => std.process.exit(1),
            else => return err,
        },
        .trust_allow => session_mgmt.cmdTrustAllow(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.InvalidTrustStore => std.process.exit(1),
            else => return err,
        },
        .trust_revoke => session_mgmt.cmdTrustRevoke(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.TrustEntryNotFound => std.process.exit(1),
            error.InvalidTrustStore => std.process.exit(1),
            else => return err,
        },
        .trust_hooks => session_mgmt.cmdTrustHooks(allocator, cwd, stdout) catch |err| switch (err) {
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_hook_allow => session_mgmt.cmdTrustHookAllow(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.HookFileNotFound, error.AccessDenied => std.process.exit(2),
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_hook_revoke => session_mgmt.cmdTrustHookRevoke(allocator, cwd, opts.subject, stdout) catch |err| switch (err) {
            error.HookTrustEntryNotFound => std.process.exit(1),
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_marketplace => session_mgmt.cmdTrustMarketplace(allocator, stdout) catch |err| switch (err) {
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_marketplace_allow => session_mgmt.cmdTrustMarketplaceAllow(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_marketplace_block => session_mgmt.cmdTrustMarketplaceBlock(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .trust_marketplace_unblock => session_mgmt.cmdTrustMarketplaceUnblock(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.MarketplacePrefixNotBlocked => std.process.exit(1),
            error.InvalidSecurityRegistry => std.process.exit(1),
            else => return err,
        },
        .prompt_inspect => session_mgmt.cmdPromptInspect(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.prompt, opts.json, opts.prompt_inspect_summary, opts.prompt_inspect_include_packets, auto_approve_high, opts.strict, yolo_mode, opts.agent, stdout) catch |err| {
            // A closed stdout pipe (`zcode prompt inspect | head`) is normal
            // Unix behavior, not a failure: stop writing and exit cleanly.
            if (err == error.BrokenPipe) std.process.exit(0);
            return err;
        },
        .providers_login => try session_mgmt.cmdProvidersLogin(opts.subject orelse cfg.default_provider, stdout),
        .providers_logout => try session_mgmt.cmdProvidersLogout(opts.subject orelse cfg.default_provider, stdout),
        .providers_status => try session_mgmt.cmdProvidersStatus(allocator, cfg, stdout),
        .keychain_set => try session_mgmt.cmdKeychainSet(allocator, opts.subject, opts.prompt, stdout),
        .keychain_get => try session_mgmt.cmdKeychainGet(allocator, opts.subject, stdout),
        .keychain_delete => session_mgmt.cmdKeychainDelete(allocator, opts.subject, stdout) catch |err| switch (err) {
            error.EntryNotInstalled => std.process.exit(1),
            error.MissingToolArg => std.process.exit(2),
            else => return err,
        },
        .keychain_list => try session_mgmt.cmdKeychainList(allocator, stdout),
        .config_show => try printResolvedConfig(allocator, cfg, stdout),
        .config_path => try printConfigPaths(allocator, stdout),
        .config_schema => try @import("core/config_schema.zig").writeSchema(stdout),
        .audit_verify => blk: {
            var resolved = try @import("core/paths.zig").resolve(allocator);
            defer resolved.deinit(allocator);
            const logs_dir = resolved.logs_dir;
            const target_path = if (opts.subject) |s|
                try allocator.dupe(u8, s)
            else pick: {
                // Default: today's audit-<bucket>.jsonl in the logs dir.
                const day_bucket: i64 = @divTrunc(clock.nowSeconds(), 86_400);
                const name = try std.fmt.allocPrint(allocator, "audit-{d}.jsonl", .{day_bucket});
                defer allocator.free(name);
                break :pick try std.fs.path.join(allocator, &.{ logs_dir, name });
            };
            defer allocator.free(target_path);

            const result = logger_mod.verifyLog(allocator, logs_dir, target_path) catch |err| switch (err) {
                // Distinguish "no log there" / "wrong kind of path" /
                // "unreadable" from the chain-break path below so the
                // operator gets an actionable hint instead of the
                // agent-runtime-style `FileNotFound (provider=...,
                // model=...)` line that used to bubble up.
                error.FileNotFound => {
                    try std_io.stderrWriter().print(
                        "error: audit verify: file not found: {s}\n  - Run `zcode config path` to see the audit log directory.\n  - Run `ls ~/.zcode/logs/` to list available audit buckets.\n",
                        .{target_path},
                    );
                    std.process.exit(2);
                },
                error.IsDir => {
                    try std_io.stderrWriter().print(
                        "error: audit verify: path is a directory, expected an audit-NNNNN.jsonl file: {s}\n  - Point at a specific bucket file, e.g. `zcode audit verify {s}/audit-20567.jsonl`.\n",
                        .{ target_path, target_path },
                    );
                    std.process.exit(2);
                },
                error.AccessDenied => {
                    try std_io.stderrWriter().print(
                        "error: audit verify: permission denied: {s}\n  - Check the file's mode and owner; zcode does not elevate.\n",
                        .{target_path},
                    );
                    std.process.exit(2);
                },
                error.InvalidHmacKey => {
                    try std_io.stderrWriter().print(
                        "error: audit verify: invalid HMAC key at {s}/hmac.key\n  - Expected exactly 32 raw bytes.\n  - Delete the key to rotate, or restore the original key before verifying archived logs.\n",
                        .{logs_dir},
                    );
                    std.process.exit(2);
                },
                error.InsecureHmacKeyPermissions => {
                    try std_io.stderrWriter().print(
                        "error: audit verify: insecure HMAC key permissions at {s}/hmac.key\n  - Run `chmod 600 {s}/hmac.key` and ensure only the owning user/admin can read it.\n",
                        .{ logs_dir, logs_dir },
                    );
                    std.process.exit(2);
                },
                else => return err,
            };
            if (result.ok) {
                try stdout.print("OK: {d} entries verified in {s}.\n", .{ result.entries, target_path });
            } else {
                try stdout.print(
                    "FAIL: chain break at line {d}: {s}\n  file: {s}\n  verified {d} entries before the break.\n",
                    .{ result.first_bad_line, result.reason, target_path, result.entries - 1 },
                );
                std.process.exit(1);
            }
            break :blk;
        },
        .session_list => try session_mgmt.cmdSessionList(allocator, store, stdout),
        .session_resume => session_mgmt.cmdSessionResume(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.subject, stdout, auto_approve_high, opts.strict, yolo_mode, opts.agent) catch |err| switch (err) {
            // session_cmds printed the targeted message already; exit
            // 2 cleanly without the Zig error trace.
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_continue => try session_mgmt.cmdSessionContinue(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.prompt, stdout, auto_approve_high, opts.strict, yolo_mode, opts.agent),
        .session_compact => session_mgmt.cmdSessionCompact(allocator, cfg, store, opts.subject, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_export => session_mgmt.cmdSessionExport(allocator, store, opts.subject, opts.markdown, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_checkpoint => session_mgmt.cmdSessionCheckpoint(allocator, cwd, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_checkpoints => session_mgmt.cmdSessionCheckpoints(allocator, store, opts.subject, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_restore => session_mgmt.cmdSessionRestore(allocator, cwd, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            error.CheckpointNotFound => std.process.exit(1),
            else => return err,
        },
        .session_share => session_mgmt.cmdSessionShare(allocator, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_import => session_mgmt.cmdSessionImport(allocator, store, opts.subject, stdout) catch |err| switch (err) {
            error.BundleReadFailed, error.MissingSessionId => std.process.exit(2),
            else => return err,
        },
        .session_undo => session_mgmt.cmdSessionUndo(allocator, cwd, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            error.CheckpointNotFound => std.process.exit(1),
            else => return err,
        },
        .session_fork => session_mgmt.cmdSessionFork(allocator, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .session_rotate_key => blk: {
            // ZCODE_SESSION_KEY wins over the keychain at load time,
            // so rotating the keychain entry while the env var is set
            // would be a silent no-op. Refuse explicitly and tell the
            // operator what to do.
            if (@import("core/env.zig").getenv("ZCODE_SESSION_KEY")) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len > 0) {
                    try stdout.writeAll(
                        "Refusing to rotate: ZCODE_SESSION_KEY is set and wins over the keychain at load time.\n" ++
                            "Rotation would not change the active key. Unset the env var first, or rotate the env value directly.\n",
                    );
                    std.process.exit(1);
                }
            }

            const new_key = try session_store.Store.rotateSessionKey(allocator);
            // Print a one-way fingerprint (SHA-256 of the key) rather
            // than a prefix of the key itself. A prefix would be 64
            // bits of the AES-256 secret leaked to terminal scrollback
            // / shell history / CI logs under the label "fingerprint".
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&new_key, &digest, .{});
            const alphabet = "0123456789abcdef";
            var hex_buf: [64]u8 = undefined;
            for (digest, 0..) |b, i| {
                hex_buf[i * 2] = alphabet[@as(usize, b >> 4)];
                hex_buf[i * 2 + 1] = alphabet[@as(usize, b & 0x0f)];
            }
            try stdout.writeAll("Session key rotated. New key stored in OS keychain.\n");
            try stdout.writeAll("Fingerprint (SHA-256, first 16 hex chars): ");
            try stdout.writeAll(hex_buf[0..16]);
            try stdout.writeAll("...\n");
            try stdout.writeAll("WARNING: sessions encrypted with the previous key are now unreadable.\n");
            try stdout.writeAll("Export them first with `zcode session export <id>` if needed.\n");
            break :blk;
        },
        .daemon_start => try session_mgmt.cmdDaemonStart(allocator, stdout),
        .daemon_status => try session_mgmt.cmdDaemonStatus(allocator, stdout),
        .daemon_stop => try session_mgmt.cmdDaemonStop(allocator, stdout),
        .daemon_handoff => session_mgmt.cmdDaemonHandoff(allocator, store, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.SessionNotFound, error.InvalidSessionId => std.process.exit(2),
            else => return err,
        },
        .daemon_serve => blk: {
            const port_str = opts.subject orelse return error.MissingToolArg;
            const port = try std.fmt.parseInt(u16, port_str, 10);
            // Token is passed via ZCODE_DAEMON_TOKEN env var by `daemon start`
            // so it does not appear in process listings. Fall back to the
            // deprecated argv form for backward-compatible invocations.
            const env_token = @import("core/env.zig").getOwned(allocator, "ZCODE_DAEMON_TOKEN") catch null;
            defer if (env_token) |t| allocator.free(t);
            const token = env_token orelse opts.prompt orelse return error.MissingToolArg;
            break :blk try remote_daemon.serve(allocator, store, port, token);
        },
        .kairos_start => {
            const msg = try kairos.start(allocator, cwd);
            defer allocator.free(msg);
            try stdout.print("{s}\n", .{msg});
        },
        .kairos_status => {
            const msg = try kairos.status(allocator, cwd);
            defer allocator.free(msg);
            try stdout.writeAll(msg);
        },
        .kairos_stop => {
            const msg = try kairos.stop(allocator, cwd);
            defer allocator.free(msg);
            try stdout.print("{s}\n", .{msg});
        },
        .kairos_serve => {
            // Detached worker launched by `kairos start`. cwd is passed in
            // argv (opts.subject); fall back to the dispatch cwd otherwise.
            const project = opts.subject orelse cwd;
            try kairos.serve(allocator, project, cfg, policy, audit, store, mcp, browser);
        },
        // phase-26 daemon-background-01/09/10: the detached-session surface.
        .ps => try bg_cmds.cmdPs(allocator, stdout),
        .kill => try bg_cmds.cmdKill(allocator, opts.subject orelse return error.MissingToolArg, stdout),
        .logs => try bg_cmds.cmdLogs(allocator, opts.subject orelse return error.MissingToolArg, stdout),
        .mcp_list => session_mgmt.cmdMcpList(allocator, mcp, stdout) catch |err| switch (err) {
            error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_tools => session_mgmt.cmdMcpTools(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_resources => session_mgmt.cmdMcpResources(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_templates => session_mgmt.cmdMcpTemplates(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_read => session_mgmt.cmdMcpRead(allocator, mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_prompts => session_mgmt.cmdMcpPrompts(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_prompt => session_mgmt.cmdMcpPrompt(allocator, mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_complete => session_mgmt.cmdMcpComplete(allocator, mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_subscribe => session_mgmt.cmdMcpSubscribe(mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_unsubscribe => session_mgmt.cmdMcpUnsubscribe(mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_log_level => session_mgmt.cmdMcpLogLevel(mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_notifications => session_mgmt.cmdMcpNotifications(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_add => session_mgmt.cmdMcpAdd(mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.InvalidMcpRegistry => std.process.exit(1),
            // Pass-41: `mcp add` on an already-registered server
            // is a runtime-not-found-but-actually-found condition;
            // exit 1 is the conventional code for "resource exists"
            // and matches `kubectl create` behavior.
            error.ServerAlreadyExists => std.process.exit(1),
            // Blocked by enterprise allow/deny MCP policy (mcp-05): the stderr
            // diagnostic is emitted inside cmdMcpAdd; exit 1.
            error.McpServerBlockedByPolicy => std.process.exit(1),
            else => return err,
        },
        .mcp_remove => session_mgmt.cmdMcpRemove(mcp, opts.subject, stdout) catch |err| switch (err) {
            // Absent-resource: exit 1 (runtime condition), no Zig
            // trace. Matches kubectl/systemctl behavior. stderr
            // diagnostic already emitted inside cmdMcpRemove.
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_test => session_mgmt.cmdMcpTest(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_auth_login => session_mgmt.cmdMcpAuthLogin(mcp, opts.subject, opts.prompt, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_auth_status => session_mgmt.cmdMcpAuthStatus(allocator, mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .mcp_auth_logout => session_mgmt.cmdMcpAuthLogout(mcp, opts.subject, stdout) catch |err| switch (err) {
            error.McpServerNotFound, error.InvalidMcpRegistry => std.process.exit(1),
            else => return err,
        },
        .policy_show => try policy.print(stdout),
        .policy_validate => {
            policy.validate() catch |err| {
                try printPolicyErrorAndExit(err, "policy.toml");
                unreachable;
            };
            try stdout.writeAll("policy valid\n");
        },
        .doctor_enterprise => {
            const ok = try enterprise_doctor.run(allocator, cwd, cfg, opts.json, stdout);
            if (!ok) std.process.exit(1);
        },
        .benchmark_run => try session_mgmt.cmdBenchmarkRun(allocator, cwd, cfg, policy, stdout),
        .api_schema => try api_server.cmdApiSchema(stdout),
        .api_serve => try api_server.cmdApiServe(allocator, cwd, cfg, policy, audit, store, mcp, browser, stdout),
        .auth_jwks_refresh => jwks_cache.cmdRefresh(allocator, cfg, stdout) catch |err| switch (err) {
            error.MissingJwksUrl => {
                try std_io.stderrWriter().writeAll(
                    "error: auth jwks refresh: api_oidc_jwks_url is not configured.\n  - Set api_oidc_jwks_url in config.toml or managed.toml.\n",
                );
                std.process.exit(2);
            },
            error.UrlPolicyDenied => {
                try std_io.stderrWriter().writeAll(
                    "error: auth jwks refresh: JWKS URL was denied by egress policy.\n  - Add the issuer host to egress_allowlist or use api_oidc_jwks_file.\n",
                );
                std.process.exit(1);
            },
            else => return err,
        },
        .review => session_mgmt.cmdReview(allocator, cwd, cfg, policy, audit, store, mcp, browser, opts.prompt, stdout, auto_approve_high, opts.strict, yolo_mode, opts.agent) catch |err| switch (err) {
            // Bogus review target already emitted its targeted stderr
            // line inside cmdReview; exit 2 silently.
            error.UsageErrorReported => std.process.exit(2),
            else => return err,
        },
        .update => try update.cmdUpdateWithConfig(allocator, cfg, stdout),
        .help => try cli.printUsage(stdout),
        .list_env => {
            // Already handled in main() before dispatch; reach this
            // arm only through an unexpected code path, in which case
            // fall through to printing the table rather than crashing.
            const env_registry = @import("core/env_registry.zig");
            const table = try env_registry.renderTable(allocator);
            defer allocator.free(table);
            try stdout.writeAll(table);
        },
        .completion => {
            const completion = @import("cli/completion.zig");
            const subject = opts.subject orelse {
                // Argparse already enforces "missing subcommand" when no
                // positional follows `completion`, but keep the branch
                // defensive in case the entry point changes.
                try std_io.stderrWriter().writeAll("error: completion: missing shell name\n  Usage: zcode completion <bash|zsh|fish>\n");
                std.process.exit(2);
            };
            const shell = completion.Shell.fromString(subject) orelse {
                // Usage error: unrecognized shell. Write the diagnostic
                // to stderr (so `zcode completion bogus > out.sh` never
                // writes a bogus-shell usage banner into the output
                // file) and exit 2. Previously exited 0 with the banner
                // on stdout, which is why completion-shell scripts
                // could silently install an empty file.
                try std_io.stderrWriter().print(
                    "error: completion: unrecognized shell '{s}'\n  Usage: zcode completion <bash|zsh|fish>\n",
                    .{subject},
                );
                std.process.exit(2);
            };
            const script = try completion.render(allocator, shell);
            defer allocator.free(script);
            try stdout.writeAll(script);
        },
    }
}

/// sdk-headless LIVE wiring entry. Routes a `.run`/`.exec` invocation into the
/// SDK serializers / control protocol when an SDK transport is selected
/// (`--output-format json|stream-json` or `--input-format stream-json`).
/// Returns true when it handled the run (the caller returns immediately);
/// false when no transport flag is set (the caller keeps the legacy path).
///
/// Three live shapes, all keyed off the resolved transport:
///   - input-format stream-json : drive the run from stdin NDJSON, with the
///     can_use_tool relay + live-control subtypes installed.
///   - output-format stream-json (text input): emit system:init + result lines
///     through the stdout guard; requires --verbose.
///   - output-format json (text input): emit a single SDK `result` object,
///     replacing the legacy encodeExecJson blob.
fn runHeadlessDispatch(
    allocator: std.mem.Allocator,
    opts: *cli.CliOptions,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    auto_approve_high: bool,
    yolo_mode: bool,
) !bool {
    const transport = sdk_headless.resolve(opts.output_format, opts.input_format) catch {
        // The format parser already printed a usage line; exit non-zero.
        std.process.exit(2);
    };
    if (!sdk_headless.isSdkShaped(transport)) return false;

    // stream-json output requires --verbose (matches the reference). The gate
    // prints its own usage line; exit non-zero on failure.
    sdk_output.validateVerboseGate(transport.output_format, opts.verbose) catch {
        std.process.exit(2);
    };

    const rc = sdk_headless.RunContext{
        .allocator = allocator,
        .cwd = cwd,
        .cfg = cfg,
        .policy = policy,
        .audit = audit,
        .store = store,
        .mcp = mcp,
        .browser = browser,
        .auto_approve_high = auto_approve_high,
        .strict = opts.strict,
        .yolo_mode = yolo_mode,
        .initial_agent = opts.agent,
        .caps = .{
            .max_turns = opts.max_turns,
            .max_budget_usd = opts.max_budget_usd,
            .json_schema = opts.json_schema,
            .max_thinking_tokens = opts.max_thinking_tokens,
        },
    };

    const stdout = std_io.stdoutWriter();
    const stderr = std_io.stderrWriter();

    // The SDK output format used for emitted messages. When only an input
    // transport is set (no --output-format), default the emission to json so
    // each turn still yields a parseable `result`.
    const out_fmt: sdk_output.OutputFormat = if (transport.output_format == .text)
        .json
    else
        transport.output_format;

    if (transport.input_format == .stream_json) {
        // Path 3: stdin-driven control pump. Read NDJSON from stdin; run each
        // user turn; relay can_use_tool to the host; route live control.
        const reader = std_io.stdinReader();
        const Session = sdk_headless.StreamSession(@TypeOf(reader), @TypeOf(stdout));
        var session = Session.init(rc, reader, stdout, out_fmt);
        session.replay_user_messages = opts.replay_user_messages;
        defer session.deinit();
        try session.run();
        return true;
    }

    // Paths 1+2: text input, single turn, SDK output. stream-json goes through
    // the stdout guard so any stray non-JSON write is diverted to stderr.
    if (out_fmt == .stream_json) {
        var guard = sdk_stdout_guard.Guard(@TypeOf(stdout), @TypeOf(stderr)).init(allocator, stdout, stderr);
        defer guard.deinit();
        const GuardWriter = struct {
            g: *sdk_stdout_guard.Guard(@TypeOf(stdout), @TypeOf(stderr)),
            pub fn writeAll(self: @This(), bytes: []const u8) !void {
                try self.g.write(bytes);
            }
        };
        try sdk_headless.runOutput(rc, .stream_json, opts.prompt orelse "", GuardWriter{ .g = &guard });
    } else {
        try sdk_headless.runOutput(rc, .json, opts.prompt orelse "", stdout);
    }
    return true;
}

// Pull in tests from all modules so `zig build test` covers them.
comptime {
    // New modules
    _ = @import("agent_runtime.zig");
    _ = @import("agent_tools.zig");
    _ = @import("agent_history.zig");
    _ = @import("api_server.zig");
    _ = @import("update.zig");
    _ = @import("repl_commands.zig");
    _ = @import("session_mgmt.zig");
    _ = @import("session_cmds.zig");
    _ = @import("provider_cmds.zig");
    _ = @import("mcp_cmds.zig");

    // Existing modules
    _ = @import("cli/args.zig");
    _ = @import("cli/repl.zig");
    _ = @import("cli/repl_spinner.zig");
    _ = @import("cli/repl_vim.zig");
    _ = @import("cli/repl_input.zig");
    _ = @import("cli/repl_markdown.zig");
    _ = @import("cli/repl_edit.zig");
    _ = @import("cli/repl_diff_nav.zig");
    _ = @import("cli/repl_render.zig");
    _ = @import("cli/repl_overlay.zig");
    _ = @import("cli/repl_agent.zig");
    _ = @import("cli/repl_session.zig");
    _ = @import("cli/repl_history.zig");
    _ = @import("cli/keybindings.zig");
    _ = @import("core/config.zig");
    _ = @import("core/config_parse.zig");
    _ = @import("core/config_schema.zig");
    _ = @import("core/managed_env.zig");
    _ = @import("core/managed_security.zig");
    _ = @import("core/agents.zig");
    _ = @import("core/agent_registry.zig");
    _ = @import("core/commands.zig");
    _ = @import("core/skill_usage.zig");
    _ = @import("core/hooks.zig");
    _ = @import("core/marketplace.zig");
    _ = @import("core/plugins.zig");
    _ = @import("core/plugin_settings.zig");
    _ = @import("core/plugin_hooks.zig");
    _ = @import("core/plugin_mcp.zig");
    _ = @import("core/plugin_deps.zig");
    _ = @import("core/plugin_policy.zig");
    _ = @import("core/plugin_version.zig");
    _ = @import("core/plugin_flagging.zig");
    _ = @import("core/plugin_autoupdate.zig");
    _ = @import("core/trust.zig");
    _ = @import("core/trust_capabilities.zig");
    _ = @import("core/idle_return.zig");
    _ = @import("core/feedback_survey.zig");
    _ = @import("core/logger.zig");
    _ = @import("core/prompt_engine.zig");
    _ = @import("core/prompt_helpers.zig");
    _ = @import("core/model_output.zig");
    _ = @import("core/approval.zig");
    _ = @import("core/sandbox.zig");
    _ = @import("core/tokenizer.zig");
    _ = @import("core/control_plane.zig");
    _ = @import("core/rate_limit.zig");
    _ = @import("core/memory.zig");
    _ = @import("core/memory_messages.zig");
    _ = @import("core/memory_gate.zig");
    _ = @import("core/effort_level.zig");
    _ = @import("core/memory_prompt.zig");
    _ = @import("core/memory_relevance.zig");
    _ = @import("core/extract_memories.zig");
    _ = @import("core/session_memory.zig");
    _ = @import("core/todos.zig");
    _ = @import("core/metrics.zig");
    _ = @import("core/otel.zig");
    _ = @import("core/fuzz_tests.zig");
    _ = @import("core/compaction.zig");
    _ = @import("core/context.zig");
    _ = @import("core/preprocessor.zig");
    _ = @import("core/instructions.zig");
    _ = @import("core/parse_helpers.zig");
    _ = @import("core/parse_xml.zig");
    _ = @import("core/parse_blocks.zig");
    _ = @import("core/parse_json.zig");
    _ = @import("core/json_normalize.zig");
    _ = @import("core/types.zig");
    _ = @import("core/paths.zig");
    _ = @import("providers/common.zig");
    _ = @import("providers/anthropic.zig");
    _ = @import("providers/openai.zig");
    _ = @import("providers/deepseek.zig");
    _ = @import("providers/gemini.zig");
    _ = @import("providers/local.zig");
    _ = @import("providers/mock.zig");
    _ = @import("providers/groq.zig");
    _ = @import("providers/openrouter.zig");
    _ = @import("providers/azure.zig");
    _ = @import("providers/circuit_breaker.zig");
    _ = @import("providers/extractors.zig");
    _ = @import("providers/mod.zig");
    _ = @import("review_flow.zig");
    _ = @import("core/cost.zig");
    _ = @import("core/model_usage.zig");
    _ = @import("core/format.zig");
    _ = @import("core/hint_protocol.zig");
    _ = @import("core/token_budget.zig");
    _ = @import("core/env.zig");
    _ = @import("core/platform.zig");
    _ = @import("core/git_url.zig");
    _ = @import("core/git_ref.zig");
    _ = @import("core/git_config.zig");
    _ = @import("core/git_fs.zig");
    _ = @import("core/prompt_keywords.zig");
    _ = @import("core/messages.zig");
    _ = @import("core/onboarding.zig");
    _ = @import("core/figures.zig");
    _ = @import("core/spinner_glyph.zig");
    _ = @import("core/fs_errors.zig");
    _ = @import("core/notifier.zig");
    _ = @import("core/word_slug.zig");
    _ = @import("core/context_suggestions.zig");
    _ = @import("core/command_semantics.zig");
    _ = @import("core/example_commands.zig");
    _ = @import("core/frontmatter.zig");
    _ = @import("core/unicode_sanitize.zig");
    _ = @import("core/which.zig");
    _ = @import("cli/completion.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/agent.zig");
    _ = @import("tools/file.zig");
    _ = @import("tools/git.zig");
    _ = @import("tools/http.zig");
    _ = @import("tools/shell.zig");
    _ = @import("tools/extended.zig");
    _ = @import("tools/fuzz_tests.zig");
    _ = @import("tools/fs_extra.zig");
    _ = @import("tools/git_extra.zig");
    _ = @import("tools/json_query.zig");
    _ = @import("tools/test_runner.zig");
    _ = @import("tools/glob.zig");
    _ = @import("tools/grep.zig");
    _ = @import("tools/team.zig");
    _ = @import("tools/teammate_mailbox.zig");
    _ = @import("tools/misc.zig");
    _ = @import("tools/notebook.zig");
    _ = @import("tools/helpers.zig");
    _ = @import("tools/tool_schemas.zig");
    _ = @import("tools/tool_dispatch.zig");
    _ = @import("tools/tool_search_score.zig");
    _ = @import("tools/config_tool.zig");
    _ = @import("tools/structured_output.zig");
    _ = @import("tools/arg_parse.zig");
    _ = @import("tools/web.zig");
    _ = @import("tools/web_summarize.zig");
    _ = @import("tools/ask_question.zig");
    _ = @import("tools/lsp.zig");
    _ = @import("tools/task.zig");
    _ = @import("session/store.zig");
    _ = @import("session/bundles.zig");
    _ = @import("mcp/client.zig");
    _ = @import("mcp/websocket.zig");
    _ = @import("core/sdk_message.zig");
    _ = @import("core/ide_lockfile.zig");
    _ = @import("mcp/ide_client.zig");
    _ = @import("core/ide_diff.zig");
    _ = @import("core/ide_selection.zig");
    _ = @import("core/ide_at_mention.zig");
    _ = @import("core/ide_path_conv.zig");
    _ = @import("core/server_session_index.zig");
    _ = @import("core/ws_reconnect.zig");
    _ = @import("remote_daemon.zig");
    _ = @import("mcp/browser_bridge.zig");
    _ = @import("mcp/parsers.zig");
    _ = @import("mcp/headers_helper.zig");
    _ = @import("mcp/fuzz_tests.zig");
    _ = @import("policy/policy.zig");
    _ = @import("session_cmds.zig");
    _ = @import("provider_cmds.zig");
    _ = @import("mcp_cmds.zig");
    _ = @import("core/otel.zig");
}

fn printPolicyErrorAndExit(err: anyerror, path: []const u8) !void {
    const stderr = std_io.stderrWriter();
    switch (err) {
        error.InvalidPolicyBool => try stderr.print(
            "error: policy error in {s}: boolean values must be true/false/yes/no/1/0.\n",
            .{path},
        ),
        error.InvalidPolicyValue => try stderr.print(
            "error: policy error in {s}: key/value contains a control byte.\n",
            .{path},
        ),
        error.InvalidPolicyKey => try stderr.print(
            "error: policy error in {s}: empty policy key.\n",
            .{path},
        ),
        error.UnknownPolicyKey => try stderr.print(
            "error: policy error in {s}: unknown key. Expected default_approval_mode, allow_network, block_destructive_shell, blocked_tool, or blocked_shell_pattern.\n",
            .{path},
        ),
        error.InvalidApprovalMode => try stderr.print(
            "error: policy error in {s}: default_approval_mode must be tiered-auto, manual, or strict.\n",
            .{path},
        ),
        error.InvalidBlockedTool => try stderr.print(
            "error: policy error in {s}: blocked_tool is empty or names an unknown tool.\n",
            .{path},
        ),
        error.InvalidBlockedShellPattern => try stderr.print(
            "error: policy error in {s}: blocked_shell_pattern must not be empty.\n",
            .{path},
        ),
        else => return err,
    }
    std.process.exit(2);
}

/// Emit the resolved (post-precedence) config as TOML-shaped key=value
/// lines. Every secret-looking field is redacted so operators can
/// paste the output into a bug report. Order is stable so diffs are
/// easy to read. Honors the documented precedence:
///   defaults < user < workspace < local < CLI/env < managed.
fn printResolvedConfig(allocator: std.mem.Allocator, cfg: *const config_mod.Config, writer: anytype) !void {
    _ = allocator;
    try writer.writeAll("# zcode resolved configuration (secrets redacted).\n");
    try writer.writeAll("# Precedence: defaults < user < workspace < settings.local.toml < CLI/env < managed.\n\n");
    try writer.print("default_provider = \"{s}\"\n", .{cfg.default_provider});
    try writer.print("default_model = \"{s}\"\n", .{cfg.default_model});
    try writer.print("fallback_provider = \"{s}\"\n", .{cfg.fallback_provider});
    try writer.print("fallback_model = \"{s}\"\n", .{cfg.fallback_model});
    try writer.print("provider_base_url = \"{s}\"\n", .{cfg.provider_base_url});
    try writer.print("provider_api_key = {s}\n", .{redactedSecretMarker(cfg.provider_api_key)});
    try writer.print("fallback_provider_base_url = \"{s}\"\n", .{cfg.fallback_provider_base_url});
    try writer.print("fallback_provider_api_key = {s}\n", .{redactedSecretMarker(cfg.fallback_provider_api_key)});
    try writer.print("local_base_url = \"{s}\"\n", .{cfg.local_base_url});
    try writer.print("provider_timeout_ms = {d}\n", .{cfg.provider_timeout_ms});
    try writer.print("provider_retry_count = {d}\n", .{cfg.provider_retry_count});
    try writer.print("approval_mode = \"{s}\"\n", .{cfg.approval_mode});
    try writer.print("sandbox = \"{s}\"\n", .{cfg.sandbox});
    try writer.print("model_context_window = {d}\n", .{cfg.model_context_window});
    try writer.print("reserved_output_tokens = {d}\n", .{cfg.reserved_output_tokens});
    try writer.print("reserved_reasoning_tokens = {d}\n", .{cfg.reserved_reasoning_tokens});
    try writer.print("session_encryption_enabled = {}\n", .{cfg.session_encryption_enabled});
    try writer.print("session_retention_days = {d}\n", .{cfg.session_retention_days});
    try writer.print("privacy_redact_prompt_bodies = {}\n", .{cfg.privacy_redact_prompt_bodies});
    try writer.print("tool_output_artifact_threshold_bytes = {d}\n", .{cfg.tool_output_artifact_threshold_bytes});
    try writer.print("feature_kill_switches = \"{s}\"\n", .{cfg.feature_kill_switches});
    try writer.print("cloud_telemetry_opt_in = {}\n", .{cfg.cloud_telemetry_opt_in});
    try writer.print("control_plane_url = \"{s}\"\n", .{cfg.control_plane_url});
    try writer.print("control_plane_token = {s}\n", .{redactedSecretMarker(cfg.control_plane_token)});
    try writer.print("control_plane_managed_settings_sync = {}\n", .{cfg.control_plane_managed_settings_sync});
    try writer.print("control_plane_managed_settings_verify_hash = {}\n", .{cfg.control_plane_managed_settings_verify_hash});
    try writer.print("api_profile = \"{s}\"\n", .{cfg.api_profile});
    try writer.print("api_role = \"{s}\"\n", .{cfg.api_role});
    try writer.print("api_auth_required = {}\n", .{cfg.api_auth_required});
    try writer.print("api_bearer_token = {s}\n", .{redactedSecretMarker(cfg.api_bearer_token)});
    try writer.print("api_oidc_issuer = \"{s}\"\n", .{cfg.api_oidc_issuer});
    try writer.print("api_oidc_audience = \"{s}\"\n", .{cfg.api_oidc_audience});
    try writer.print("api_oidc_hs256_secret = {s}\n", .{redactedSecretMarker(cfg.api_oidc_hs256_secret)});
    try writer.print("api_oidc_jwks_json = {s}\n", .{redactedSecretMarker(cfg.api_oidc_jwks_json)});
    try writer.print("api_oidc_jwks_file = \"{s}\"\n", .{cfg.api_oidc_jwks_file});
    try writer.print("api_oidc_jwks_url = \"{s}\"\n", .{cfg.api_oidc_jwks_url});
    try writer.print("api_oidc_jwks_cache_ttl_seconds = {d}\n", .{cfg.api_oidc_jwks_cache_ttl_seconds});
    try writer.print("update_require_signature = {}\n", .{cfg.update_require_signature});
    try writer.print("update_pinned_version = \"{s}\"\n", .{cfg.update_pinned_version});
    try writer.print("managed_locked_keys = \"{s}\"\n", .{cfg.managed_locked_keys});
    try writer.print("managed_config_sources = \"{s}\"\n", .{cfg.managed_config_sources});
    try writer.print("preferred_language = \"{s}\"\n", .{cfg.preferred_language});
}

fn redactedSecretMarker(value: []const u8) []const u8 {
    return if (value.len == 0) "\"\"" else "\"<redacted; set>\"";
}

/// Emit the paths zcode reads config from, in precedence order. Useful
/// for `zcode config path` debugging ("why isn't my change taking
/// effect?").
fn printConfigPaths(allocator: std.mem.Allocator, writer: anytype) !void {
    var resolved = try @import("core/paths.zig").resolve(allocator);
    defer resolved.deinit(allocator);
    try writer.writeAll("# Config sources, highest precedence last:\n");
    try writer.writeAll("# (Each file is optional; missing files are silently skipped.)\n");
    try writer.print("user_config      = {s}\n", .{resolved.user_config_path});
    try writer.print("policy           = {s}\n", .{resolved.policy_path});
    try writer.print("permission_rules = {s}\n", .{resolved.permission_rules_path});
    try writer.print("sessions_dir     = {s}\n", .{resolved.sessions_dir});
    try writer.print("logs_dir         = {s}\n", .{resolved.logs_dir});
    try writer.print("mcp_registry     = {s}\n", .{resolved.mcp_registry_path});
    try writer.print("keybindings      = {s}\n", .{resolved.keybindings_path});

    const managed_path = @import("core/config_parse.zig").resolveManagedConfigPath(allocator) catch null;
    if (managed_path) |p| {
        defer allocator.free(p);
        const managed_dropins = try @import("core/config_parse.zig").resolveManagedDropInDirPath(allocator, p);
        defer allocator.free(managed_dropins);
        try writer.print("managed_config   = {s}  (strict, highest precedence when readable)\n", .{p});
        try writer.print("managed_dropins  = {s}  (sorted *.toml, later files win)\n", .{managed_dropins});
    } else {
        try writer.writeAll("managed_config   = (none)\n");
        try writer.writeAll("managed_dropins  = (none)\n");
    }
}

const testing = std.testing;

test "main module compiles and version is available" {
    try testing.expect(build_options.app_version.len > 0);
}
