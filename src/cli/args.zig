const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../core/std_io.zig");

// libc setenv (Zig 0.16 has no std wrapper). Used to mirror --bare/--no-memory
// into the env-equivalents that core/memory_gate.zig reads as its single
// source of truth, the same way claude-code-main keys off CLAUDE_CODE_SIMPLE /
// CLAUDE_CODE_DISABLE_AUTO_MEMORY.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub const CommandKind = enum {
    repl,
    run,
    exec,
    version,
    models_list,
    models_test,
    providers_login,
    providers_logout,
    providers_status,
    session_list,
    session_resume,
    session_continue,
    session_compact,
    session_export,
    session_checkpoint,
    session_checkpoints,
    session_restore,
    session_share,
    session_import,
    session_undo,
    session_fork,
    session_rotate_key,
    daemon_start,
    daemon_status,
    daemon_stop,
    daemon_handoff,
    daemon_serve,
    kairos_start,
    kairos_status,
    kairos_stop,
    kairos_serve,
    // phase-26 daemon-background-01/09/10: detached background-session surface.
    // `ps` renders the live-process registry, `kill` SIGTERMs a registered
    // session, `logs` tails a --bg session's captured output.
    ps,
    kill,
    logs,
    agents_list,
    agents_show,
    hooks_list,
    marketplace_sources,
    marketplace_add,
    marketplace_remove,
    marketplace_refresh,
    plugins_list,
    plugins_show,
    plugins_marketplace,
    plugins_install,
    plugins_uninstall,
    plugins_update,
    plugins_enable,
    plugins_disable,
    plugins_disable_all,
    commands_list,
    commands_show,
    commands_run,
    commands_marketplace,
    commands_install,
    commands_uninstall,
    commands_update,
    skills_list,
    skills_show,
    skills_run,
    trust_status,
    trust_allow,
    trust_revoke,
    trust_hooks,
    trust_hook_allow,
    trust_hook_revoke,
    trust_marketplace,
    trust_marketplace_allow,
    trust_marketplace_block,
    trust_marketplace_unblock,
    review,
    mcp_list,
    mcp_tools,
    mcp_resources,
    mcp_templates,
    mcp_read,
    mcp_prompts,
    mcp_prompt,
    mcp_complete,
    mcp_subscribe,
    mcp_unsubscribe,
    mcp_log_level,
    mcp_notifications,
    mcp_add,
    mcp_remove,
    mcp_test,
    mcp_auth_login,
    mcp_auth_status,
    mcp_auth_logout,
    policy_show,
    policy_validate,
    doctor_enterprise,
    prompt_inspect,
    benchmark_run,
    api_schema,
    api_serve,
    auth_jwks_refresh,
    update,
    keychain_set,
    keychain_get,
    keychain_delete,
    keychain_list,
    audit_verify,
    config_show,
    config_path,
    config_schema,
    help,
    completion,
    list_env,
};

/// settings-05: parsed `--setting-sources` selection. Gates which of the
/// non-forced config layers (user/workspace/local) load. The `policy`
/// (managed) and `flag` (CLI) sources are always forced on and are not
/// represented here, matching the reference `getEnabledSettingSources`
/// which unconditionally adds policy + flag. When the flag is absent, the
/// `CliOptions.setting_sources` field stays null and every layer loads.
pub const SettingSources = struct {
    /// User-scope config (~/.zcode/config.toml). Reference token: `user`.
    user: bool = false,
    /// Workspace-scope config (.zcode/config.toml). Reference token:
    /// `project`.
    project: bool = false,
    /// Local-scope overrides (.zcode/settings.local.toml). Reference
    /// token: `local`.
    local: bool = false,
};

/// Parse a comma-separated `--setting-sources` value into a SettingSources
/// selection. Accepts the reference tokens `user`, `project`, `local`
/// (case-sensitive, mirroring the reference). Empty tokens (e.g. a
/// trailing comma) are skipped. An unknown token returns
/// error.InvalidSettingSource so the caller can fail fast instead of
/// silently dropping a misspelled scope. An all-empty value (no recognized
/// tokens) is rejected too, since `--setting-sources ""` almost certainly
/// signals a scripting mistake rather than "load nothing".
pub fn parseSettingSources(value: []const u8) !SettingSources {
    var sources: SettingSources = .{};
    var saw_any = false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (token.len == 0) continue;
        if (std.mem.eql(u8, token, "user")) {
            sources.user = true;
        } else if (std.mem.eql(u8, token, "project")) {
            sources.project = true;
        } else if (std.mem.eql(u8, token, "local")) {
            sources.local = true;
        } else {
            std_io.stderrWriter().print(
                "error: --setting-sources: unknown source '{s}'. Valid sources: user, project, local.\n",
                .{token},
            ) catch {};
            return error.InvalidSettingSource;
        }
        saw_any = true;
    }
    if (!saw_any) return error.InvalidSettingSource;
    return sources;
}

pub const CliOptions = struct {
    command: CommandKind = .repl,
    prompt: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    /// session export <id> md|markdown -> emit Markdown instead of JSON.
    markdown: bool = false,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    approval_mode: ?[]const u8 = null,
    sandbox: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    /// `--scope user|workspace` for the plugins enable/disable/disable-all
    /// verbs (plugins-01). When unset the dispatcher picks the most specific
    /// scope (workspace if a workspace `.zcode` exists, else user).
    scope: ?[]const u8 = null,
    /// Path to a settings.json read as the `flag` settings source
    /// (highest scalar-override precedence below policy). Mirrors the
    /// reference `--settings <path>` flag that feeds the flagSettings
    /// source in `core/settings_sources.zig`.
    settings_path: ?[]const u8 = null,
    /// settings-05: `--setting-sources user,project,local` restricts which
    /// non-forced config layers load. Null = flag absent = all layers load
    /// (byte-identical to legacy behavior). Managed (policy) and CLI (flag)
    /// always apply regardless of this selection. See parseSettingSources.
    setting_sources: ?SettingSources = null,
    json: bool = false,
    /// sdk-headless-01: `--print` ran a single non-interactive turn and
    /// exited, matching Claude Code's `-p, --print`. zcode maps it onto
    /// the existing one-shot `run`/`exec` execution rather than a new
    /// code path. NOTE the deliberate divergence: `-p` stays bound to
    /// `--provider` for backward compat, so `--print` has NO short alias
    /// in zcode (documented in --help).
    print: bool = false,
    /// sdk-headless-01: the headless gate. Set by `--print` (and implied
    /// by the `run`/`exec` subcommands). Only when this is set are the
    /// SDK transport flags (`--output-format`, `--input-format`, and the
    /// later `--max-turns`/`--max-budget-usd`/etc.) honored, matching the
    /// reference which gates those behind `-p/--print`.
    headless: bool = false,
    /// sdk-headless-02: `--output-format text|json|stream-json`. Stored as
    /// a raw string here; the format enum + validation + serializer live
    /// in the output dispatcher (sdk-headless-02). Only honored under the
    /// headless gate.
    output_format: ?[]const u8 = null,
    /// sdk-headless-03: `--input-format text|stream-json`. Stored raw; the
    /// streaming-stdin reader (sdk-headless-03) consumes it. Only honored
    /// under the headless gate.
    input_format: ?[]const u8 = null,
    /// sdk-headless-14: `--max-turns N` caps the tool-call rounds for a
    /// headless run. Threaded into AgentRuntime.max_tool_rounds_override;
    /// on exceed the SDK result carries the `error_max_turns` subtype.
    /// Only honored under the headless gate.
    max_turns: ?usize = null,
    /// sdk-headless-14: `--max-budget-usd X` caps the estimated spend for a
    /// headless run. Parsed as a float; full per-turn USD enforcement in the
    /// runtime loop is a follow-on (the data feeds the result message path).
    /// Only honored under the headless gate.
    max_budget_usd: ?f64 = null,
    /// sdk-headless-14: `--json-schema <schema|@file>` sets the structured-
    /// output schema (the `/format json` internal path), threaded into
    /// AgentRuntime.pending_response_schema. A leading `@` reads the schema
    /// from a file. Only honored under the headless gate.
    json_schema: ?[]const u8 = null,
    /// Backing buffer when --json-schema is read from a file (the `@file`
    /// form). Freed in deinit so the parsed slice stays valid until then.
    _owned_json_schema: ?[]u8 = null,
    /// sdk-headless-14: `--fork-session` forks the resumed/continued session
    /// into a fresh copy before the headless run, so the run does not mutate
    /// the original transcript. Only honored under the headless gate.
    fork_session: bool = false,
    /// sdk-headless-14: `--thinking` / `--max-thinking-tokens N` sets the
    /// reserved reasoning-token budget for a headless run. `--thinking` with
    /// no value is a sentinel "on"; `--max-thinking-tokens N` (or
    /// `--thinking N`) sets an explicit cap. Threaded into
    /// AgentRuntime.reserved_reasoning_tokens_override. Only honored under
    /// the headless gate.
    max_thinking_tokens: ?usize = null,
    /// sdk-headless-14 (Task K2): `--permission-prompt-tool <name>` routes
    /// tool-permission prompts to a named MCP tool (`mcp__server__tool`)
    /// instead of relaying `can_use_tool` to an SDK host or prompting on stdin.
    /// The named tool receives the permission-request payload and its
    /// `{behavior: "allow"|"deny"}` result becomes the decision (sdk/
    /// permission_prompt_tool.zig). Only honored under the headless gate.
    permission_prompt_tool: ?[]const u8 = null,
    /// sdk-headless-12: `--include-partial-messages` opts the stream-json
    /// output into per-chunk `stream_event` messages (token deltas) alongside
    /// the assistant/result messages. Only honored under the headless gate and
    /// with `--output-format stream-json`.
    include_partial_messages: bool = false,
    /// sdk-headless-12: `--include-hook-events` opts the stream-json output
    /// into hook-lifecycle system events emitted to stdout when a hook fires.
    /// Only honored under the headless gate and with `--output-format
    /// stream-json`.
    include_hook_events: bool = false,
    /// sdk-headless-12: `--replay-user-messages` re-emits each accepted
    /// SDKUserMessage as a `user` NDJSON line on stdout for ack. Only honored
    /// under the headless gate and with `--output-format stream-json`.
    replay_user_messages: bool = false,
    no_color: bool = false,
    no_fullscreen: bool = false,
    no_spinner: bool = false,
    no_thinking_summary: bool = false,
    no_stream: bool = false,
    preprocessor_enabled: ?bool = null,
    preprocessor_provider: ?[]const u8 = null,
    preprocessor_model: ?[]const u8 = null,
    preprocessor_base_url: ?[]const u8 = null,
    preprocessor_api_key: ?[]const u8 = null,
    preprocessor_max_output_tokens: ?usize = null,
    output_style: ?[]const u8 = null,
    prompt_label: ?[]const u8 = null,
    prompt_inspect_summary: bool = false,
    prompt_inspect_include_packets: bool = true,
    transcript_max_lines: ?usize = null,
    /// CLI-supplied --append-system-prompt. When set, OVERRIDES
    /// the value parsed from config.toml for the duration of the
    /// session. The prompt_engine appends this block to the base
    /// system prompt on every turn. Ported from claude-code-main's
    /// --append-system-prompt flag in main.tsx.
    append_system_prompt: ?[]const u8 = null,
    /// CLI-supplied --append-system-prompt-file. Read and merged
    /// into append_system_prompt at parse time so downstream code
    /// only needs to consult one field. Empty or missing file
    /// produces an error so a misconfigured pipeline doesn't
    /// silently run with no override.
    _owned_append_system_prompt: ?[]u8 = null,
    strict: bool = false,
    approve_high: bool = false,
    yolo: bool = false,
    /// phase-26 daemon-background-01: `--bg` / `--background` spawns the
    /// requested run detached (stdout/stderr redirected to a per-session log
    /// file recorded in the live-process registry) and returns immediately
    /// instead of entering the REPL. The detached child self-registers with
    /// kind `bg` via ZCODE_SESSION_KIND (set in its env by the spawner).
    bg: bool = false,
    /// phase-26 daemon-background-11: `-n` / `--name <name>` seeds the
    /// session's display name. It is written into the live-process registry
    /// entry's `name` field (so `zcode ps` shows it) and set as the session
    /// label via `store.setLabel` (so `zcode session list` shows it too).
    /// A `--bg` spawner also forwards it as ZCODE_SESSION_NAME so the detached
    /// child self-names. Mirrors the reference `main.tsx` `-n, --name <name>`.
    name: ?[]const u8 = null,
    /// --bare / --simple: minimal mode. Among other things this disables
    /// the auto-memory subsystem (taxonomy prompt, MEMORY.md index, turn-end
    /// extraction). Mirrors claude-code-main's CLAUDE_CODE_SIMPLE gate
    /// (memdir/paths.ts:41). Parsed into the ZCODE_SIMPLE env-equivalent that
    /// core/memory_gate.zig reads.
    bare: bool = false,
    /// --no-memory: force-disable auto-memory for this run, equivalent to
    /// setting auto_memory_enabled = false (memory-10). Read by
    /// core/memory_gate.zig via the ZCODE_DISABLE_AUTO_MEMORY env-equivalent.
    no_memory: bool = false,
    verbose: bool = false,
    /// `--accessible` is a composite flag that sets `no_color`,
    /// `no_spinner`, `no_thinking_summary`, and `no_fullscreen` in
    /// one move. Target audience: screen-reader users (ANSI escapes
    /// confuse most screen readers; animated frames re-read the
    /// same content), people on prefers-reduced-motion setups, and
    /// anyone piping output into a log ingest. Individual flags are
    /// still respected when set separately -- --accessible just flips
    /// them all on.
    accessible: bool = false,
    /// Suppress non-essential output. Only the core result and errors
    /// are emitted. Implies --no-spinner and --no-thinking-summary.
    /// Does NOT imply --no-color (that's a separate visual concern).
    quiet: bool = false,
    /// Runtime log-level override (`debug|info|warn|error`). When
    /// unset, defaults to `warn` so routine operations don't flood
    /// stderr. Honored by main.zig's std.log.logFn installation.
    log_level: ?[]const u8 = null,
    /// Runtime log format: `text` (default, human-readable) or
    /// `json` (one JSON object per line with ts, level, ctx, msg).
    /// JSON is the expected format for log aggregators.
    log_format: ?[]const u8 = null,
    _owned_prompt: ?[]u8 = null,

    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        if (self._owned_prompt) |owned| {
            allocator.free(owned);
            self._owned_prompt = null;
            self.prompt = null;
        }
        if (self._owned_append_system_prompt) |owned| {
            allocator.free(owned);
            self._owned_append_system_prompt = null;
            self.append_system_prompt = null;
        }
        if (self._owned_json_schema) |owned| {
            allocator.free(owned);
            self._owned_json_schema = null;
            self.json_schema = null;
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) !CliOptions {
    var options: CliOptions = .{};
    var positional = std.array_list.Managed([]const u8).init(allocator);
    defer positional.deinit();

    // Standard Unix `--` separator: once we see a standalone "--", stop
    // option processing and treat every subsequent arg as a positional
    // even if it starts with a dash. Matches what Claude Code's
    // src/utils/cliArgs.ts extractArgsAfterDoubleDash achieves, and what
    // POSIX utility argument syntax guideline 10 mandates. Lets users
    // do `zcode run -- --literally a prompt` without tripping the
    // UnknownFlag error.
    var stop_options: bool = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (stop_options) {
            try positional.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            stop_options = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--json")) {
                options.json = true;
            } else if (std.mem.eql(u8, arg, "--bg") or std.mem.eql(u8, arg, "--background")) {
                // phase-26 daemon-background-01: detach the run instead of
                // entering the REPL. Resolved in dispatch once the command
                // (.repl vs .run) is known.
                options.bg = true;
            } else if (std.mem.eql(u8, arg, "--print")) {
                // sdk-headless-01: headless one-shot. Sets the headless
                // gate; the final command (.run vs the output-format
                // dispatcher) is resolved after positional parsing, once
                // we know whether --output-format was also supplied.
                options.print = true;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--output-format") or std.mem.startsWith(u8, arg, "--output-format=")) {
                // sdk-headless-02 stores the raw value; the enum + the
                // serializer dispatch land in that task. Imply the
                // headless gate so the selector is honored even without
                // an explicit --print (matching run/exec being headless).
                options.output_format = try parseFlagValue(argv, &i, arg, "--output-format");
                try rejectControlChars("--output-format", options.output_format.?);
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--input-format") or std.mem.startsWith(u8, arg, "--input-format=")) {
                // sdk-headless-03 consumes the raw value.
                options.input_format = try parseFlagValue(argv, &i, arg, "--input-format");
                try rejectControlChars("--input-format", options.input_format.?);
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--max-turns") or std.mem.startsWith(u8, arg, "--max-turns=")) {
                // sdk-headless-14: cap tool-call rounds for a headless run.
                const raw = try parseFlagValue(argv, &i, arg, "--max-turns");
                // parseInt rejects non-numeric values (e.g. "abc") with
                // error.InvalidCharacter, surfaced to main.zig as a flag error.
                const val = try std.fmt.parseInt(usize, raw, 10);
                // 0 turns is a misconfiguration: the runtime clamps a 0
                // override to 1, so a literal 0 here almost certainly means
                // the caller fat-fingered the value. Reject it explicitly.
                if (val == 0) return error.InvalidFlagValue;
                options.max_turns = val;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--max-budget-usd") or std.mem.startsWith(u8, arg, "--max-budget-usd=")) {
                // sdk-headless-14: cap estimated spend for a headless run.
                const raw = try parseFlagValue(argv, &i, arg, "--max-budget-usd");
                const val = std.fmt.parseFloat(f64, raw) catch return error.InvalidFlagValue;
                if (!(val > 0) or std.math.isNan(val) or std.math.isInf(val)) return error.InvalidFlagValue;
                options.max_budget_usd = val;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--json-schema") or std.mem.startsWith(u8, arg, "--json-schema=")) {
                // sdk-headless-14: structured-output schema. A leading `@`
                // reads the schema from a file (matching the reference's
                // @file convention for large schemas).
                const raw = try parseFlagValue(argv, &i, arg, "--json-schema");
                if (raw.len > 1 and raw[0] == '@') {
                    const path = raw[1..];
                    // Cap at 1 MiB like --append-system-prompt-file; a schema
                    // larger than that is almost certainly a mistake.
                    // readFileAlloc(.limited(N)) yields error.StreamTooLong on
                    // overflow in 0.16, handled in the switch below.
                    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1 * 1024 * 1024)) catch |err| {
                        const stderr = std_io.stderrWriter();
                        switch (err) {
                            error.FileNotFound => stderr.print(
                                "error: --json-schema: no such file: {s}\n",
                                .{path},
                            ) catch {},
                            error.AccessDenied => stderr.print(
                                "error: --json-schema: permission denied reading {s}\n",
                                .{path},
                            ) catch {},
                            error.IsDir => stderr.print(
                                "error: --json-schema: path is a directory, expected a regular file: {s}\n",
                                .{path},
                            ) catch {},
                            error.StreamTooLong => stderr.print(
                                "error: --json-schema: file exceeds the 1 MiB cap: {s}\n",
                                .{path},
                            ) catch {},
                            else => stderr.print(
                                "error: --json-schema: cannot read {s} ({s}).\n",
                                .{ path, @errorName(err) },
                            ) catch {},
                        }
                        return error.FlagFileUnreadable;
                    };
                    options._owned_json_schema = bytes;
                    options.json_schema = bytes;
                } else {
                    options.json_schema = raw;
                }
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--fork-session")) {
                // sdk-headless-14: fork the resumed session before running.
                options.fork_session = true;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--thinking")) {
                // sdk-headless-14: bare `--thinking` is a sentinel "on". It does
                // not consume the next argv token (that would swallow a trailing
                // prompt). Use --max-thinking-tokens or --thinking=N for an
                // explicit cap. The sentinel maps to the config default at
                // wiring time; we represent "on, default" as 0-means-unset by
                // leaving max_thinking_tokens null but flipping the gate.
                options.headless = true;
            } else if (std.mem.startsWith(u8, arg, "--thinking=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--thinking");
                options.max_thinking_tokens = try std.fmt.parseInt(usize, raw, 10);
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--max-thinking-tokens") or std.mem.startsWith(u8, arg, "--max-thinking-tokens=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--max-thinking-tokens");
                options.max_thinking_tokens = try std.fmt.parseInt(usize, raw, 10);
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--permission-prompt-tool") or std.mem.startsWith(u8, arg, "--permission-prompt-tool=")) {
                // sdk-headless-14 (Task K2): route permission prompts to a named
                // MCP tool. The value is the canonical mcp__server__tool name;
                // the runtime parses + invokes it via sdk/permission_prompt_tool.
                options.permission_prompt_tool = try parseFlagValue(argv, &i, arg, "--permission-prompt-tool");
                try rejectControlChars("--permission-prompt-tool", options.permission_prompt_tool.?);
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--include-partial-messages")) {
                // sdk-headless-12: emit per-chunk stream_event messages in
                // stream-json output. Bool flag; implies the headless gate.
                options.include_partial_messages = true;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--include-hook-events")) {
                // sdk-headless-12: emit hook-lifecycle system events in
                // stream-json output. Bool flag; implies the headless gate.
                options.include_hook_events = true;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--replay-user-messages")) {
                // sdk-headless-12: re-emit accepted user messages on stdout.
                // Bool flag; implies the headless gate.
                options.replay_user_messages = true;
                options.headless = true;
            } else if (std.mem.eql(u8, arg, "--no-color")) {
                options.no_color = true;
            } else if (std.mem.eql(u8, arg, "--no-fullscreen")) {
                options.no_fullscreen = true;
            } else if (std.mem.eql(u8, arg, "--no-spinner")) {
                options.no_spinner = true;
            } else if (std.mem.eql(u8, arg, "--no-thinking-summary")) {
                options.no_thinking_summary = true;
            } else if (std.mem.eql(u8, arg, "--no-stream")) {
                options.no_stream = true;
            } else if (std.mem.eql(u8, arg, "--summary")) {
                options.prompt_inspect_summary = true;
                options.prompt_inspect_include_packets = false;
            } else if (std.mem.eql(u8, arg, "--no-packets")) {
                options.prompt_inspect_include_packets = false;
            } else if (std.mem.eql(u8, arg, "--preprocessor")) {
                options.preprocessor_enabled = true;
            } else if (std.mem.eql(u8, arg, "--no-preprocessor")) {
                options.preprocessor_enabled = false;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                options.strict = true;
            } else if (std.mem.eql(u8, arg, "--approve-high")) {
                options.approve_high = true;
            } else if (std.mem.eql(u8, arg, "--yolo")) {
                options.yolo = true;
            } else if (std.mem.eql(u8, arg, "--bare") or std.mem.eql(u8, arg, "--simple")) {
                // --bare disables auto-memory (among other minimal-mode
                // effects). The gate (core/memory_gate.zig) is the single
                // source of truth and reads ZCODE_SIMPLE, so mirror the flag
                // into the env-equivalent the same way claude-code-main keys
                // off CLAUDE_CODE_SIMPLE.
                options.bare = true;
                _ = setenv("ZCODE_SIMPLE", "1", 1);
            } else if (std.mem.eql(u8, arg, "--no-memory")) {
                // Force-disable auto-memory for this run. memory_gate reads
                // ZCODE_DISABLE_AUTO_MEMORY (truthy = OFF) as the highest-
                // priority env override, so set it here.
                options.no_memory = true;
                _ = setenv("ZCODE_DISABLE_AUTO_MEMORY", "1", 1);
            } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
                options.verbose = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                options.quiet = true;
                options.no_spinner = true;
                options.no_thinking_summary = true;
            } else if (std.mem.eql(u8, arg, "--log-level") or std.mem.startsWith(u8, arg, "--log-level=")) {
                options.log_level = try parseFlagValue(argv, &i, arg, "--log-level");
            } else if (std.mem.eql(u8, arg, "--log-format") or std.mem.startsWith(u8, arg, "--log-format=")) {
                options.log_format = try parseFlagValue(argv, &i, arg, "--log-format");
            } else if (std.mem.eql(u8, arg, "--accessible")) {
                options.accessible = true;
                options.no_color = true;
                options.no_spinner = true;
                options.no_thinking_summary = true;
                options.no_fullscreen = true;
            } else if (std.mem.eql(u8, arg, "--version")) {
                options.command = .version;
                return options;
            } else if (std.mem.eql(u8, arg, "--list-env")) {
                options.command = .list_env;
                return options;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                options.command = .help;
                return options;
            } else if (std.mem.eql(u8, arg, "--name") or std.mem.startsWith(u8, arg, "--name=")) {
                // phase-26 daemon-background-11: session display name at
                // creation. parseFlagValue already errors on an empty value
                // (the `--name=` form), satisfying "reject empty". The short
                // `-n <name>` form is handled in the single-dash switch below.
                options.name = try parseFlagValue(argv, &i, arg, "--name");
                try rejectControlChars("--name", options.name.?);
            } else if (std.mem.eql(u8, arg, "--model") or std.mem.startsWith(u8, arg, "--model=")) {
                options.model = try parseFlagValue(argv, &i, arg, "--model");
                try rejectControlChars("--model", options.model.?);
            } else if (std.mem.eql(u8, arg, "--provider") or std.mem.startsWith(u8, arg, "--provider=")) {
                options.provider = try parseFlagValue(argv, &i, arg, "--provider");
                try rejectControlChars("--provider", options.provider.?);
            } else if (std.mem.eql(u8, arg, "--agent") or std.mem.startsWith(u8, arg, "--agent=")) {
                options.agent = try parseFlagValue(argv, &i, arg, "--agent");
                try rejectControlChars("--agent", options.agent.?);
            } else if (std.mem.eql(u8, arg, "--profile") or std.mem.startsWith(u8, arg, "--profile=")) {
                options.profile = try parseFlagValue(argv, &i, arg, "--profile");
                try rejectControlChars("--profile", options.profile.?);
            } else if (std.mem.eql(u8, arg, "--approval-mode") or std.mem.startsWith(u8, arg, "--approval-mode=")) {
                options.approval_mode = try parseFlagValue(argv, &i, arg, "--approval-mode");
                try rejectControlChars("--approval-mode", options.approval_mode.?);
            } else if (std.mem.eql(u8, arg, "--sandbox") or std.mem.startsWith(u8, arg, "--sandbox=")) {
                options.sandbox = try parseFlagValue(argv, &i, arg, "--sandbox");
                try rejectControlChars("--sandbox", options.sandbox.?);
            } else if (std.mem.eql(u8, arg, "--output-style") or std.mem.startsWith(u8, arg, "--output-style=")) {
                options.output_style = try parseFlagValue(argv, &i, arg, "--output-style");
                try rejectControlChars("--output-style", options.output_style.?);
            } else if (std.mem.eql(u8, arg, "--cwd") or std.mem.startsWith(u8, arg, "--cwd=")) {
                options.cwd = try parseFlagValue(argv, &i, arg, "--cwd");
                try rejectControlChars("--cwd", options.cwd.?);
            } else if (std.mem.eql(u8, arg, "--settings") or std.mem.startsWith(u8, arg, "--settings=")) {
                options.settings_path = try parseFlagValue(argv, &i, arg, "--settings");
                try rejectControlChars("--settings", options.settings_path.?);
            } else if (std.mem.eql(u8, arg, "--setting-sources") or std.mem.startsWith(u8, arg, "--setting-sources=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--setting-sources");
                try rejectControlChars("--setting-sources", raw);
                options.setting_sources = try parseSettingSources(raw);
            } else if (std.mem.eql(u8, arg, "--scope") or std.mem.startsWith(u8, arg, "--scope=")) {
                options.scope = try parseFlagValue(argv, &i, arg, "--scope");
                try rejectControlChars("--scope", options.scope.?);
            } else if (std.mem.eql(u8, arg, "--prompt-label") or std.mem.startsWith(u8, arg, "--prompt-label=")) {
                options.prompt_label = try parseFlagValue(argv, &i, arg, "--prompt-label");
                try rejectControlChars("--prompt-label", options.prompt_label.?);
            } else if (std.mem.eql(u8, arg, "--preprocessor-provider") or std.mem.startsWith(u8, arg, "--preprocessor-provider=")) {
                options.preprocessor_provider = try parseFlagValue(argv, &i, arg, "--preprocessor-provider");
            } else if (std.mem.eql(u8, arg, "--preprocessor-model") or std.mem.startsWith(u8, arg, "--preprocessor-model=")) {
                options.preprocessor_model = try parseFlagValue(argv, &i, arg, "--preprocessor-model");
            } else if (std.mem.eql(u8, arg, "--preprocessor-base-url") or std.mem.startsWith(u8, arg, "--preprocessor-base-url=")) {
                options.preprocessor_base_url = try parseFlagValue(argv, &i, arg, "--preprocessor-base-url");
            } else if (std.mem.eql(u8, arg, "--preprocessor-api-key") or std.mem.startsWith(u8, arg, "--preprocessor-api-key=")) {
                options.preprocessor_api_key = try parseFlagValue(argv, &i, arg, "--preprocessor-api-key");
            } else if (std.mem.eql(u8, arg, "--preprocessor-max-output-tokens") or std.mem.startsWith(u8, arg, "--preprocessor-max-output-tokens=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--preprocessor-max-output-tokens");
                const val = try std.fmt.parseInt(usize, raw, 10);
                // Reject 0 explicitly instead of silently substituting a
                // default. A user who passes 0 probably expects the flag
                // to take effect in some way; swallowing it is a silent
                // misconfiguration footgun.
                if (val == 0) return error.InvalidFlagValue;
                options.preprocessor_max_output_tokens = @min(val, 16 * 1024 * 1024);
            } else if (std.mem.eql(u8, arg, "--transcript-max-lines") or std.mem.startsWith(u8, arg, "--transcript-max-lines=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--transcript-max-lines");
                const val = try std.fmt.parseInt(usize, raw, 10);
                if (val == 0) return error.InvalidFlagValue;
                options.transcript_max_lines = @min(val, 10_000_000);
            } else if (std.mem.eql(u8, arg, "--append-system-prompt") or std.mem.startsWith(u8, arg, "--append-system-prompt=")) {
                const raw = try parseFlagValue(argv, &i, arg, "--append-system-prompt");
                // Cap at 64 KiB to match cfg.instruction_file_cap_bytes
                // (the per-file limit for instruction fragments).
                // Shell ARG_MAX is ~256 KiB on macOS / 2 MiB on
                // Linux, so an argv blob that exceeds 64 KiB is
                // almost certainly a mistake (or a programmatic
                // caller abusing exec*). The --append-system-prompt-
                // file alternative exists specifically for larger
                // inputs, with its own 1 MiB cap and file-read path.
                const cap_bytes: usize = 64 * 1024;
                if (raw.len > cap_bytes) {
                    try std_io.stderrWriter().print(
                        "error: --append-system-prompt: value is {d} bytes, exceeds the {d} KiB inline cap.\n  - Move the text to a file and pass --append-system-prompt-file <path> instead.\n",
                        .{ raw.len, cap_bytes / 1024 },
                    );
                    return error.FlagValueTooLarge;
                }
                options.append_system_prompt = raw;
            } else if (std.mem.eql(u8, arg, "--append-system-prompt-file") or std.mem.startsWith(u8, arg, "--append-system-prompt-file=")) {
                const path = try parseFlagValue(argv, &i, arg, "--append-system-prompt-file");
                // Read the file now so downstream code only sees a
                // single string. Cap at 1 MiB to keep a pathological
                // input from blowing process memory before the
                // system-prompt budget check kicks in.
                // Surface a targeted stderr line for each failure
                // class so the user doesn't get a bare error-enum
                // name ("error.InvalidFlagValue") from main.zig's
                // catch block.
                const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(1 * 1024 * 1024)) catch |err| {
                    const stderr = std_io.stderrWriter();
                    switch (err) {
                        error.FileNotFound => stderr.print(
                            "error: --append-system-prompt-file: no such file: {s}\n",
                            .{path},
                        ) catch {},
                        error.AccessDenied => stderr.print(
                            "error: --append-system-prompt-file: permission denied reading {s}\n  - Check the file's mode and owner; zcode does not elevate.\n",
                            .{path},
                        ) catch {},
                        error.IsDir => stderr.print(
                            "error: --append-system-prompt-file: path is a directory, expected a regular file: {s}\n",
                            .{path},
                        ) catch {},
                        error.FileTooBig => stderr.print(
                            "error: --append-system-prompt-file: file exceeds the 1 MiB cap: {s}\n  - Split it or prune the prompt before feeding it in.\n",
                            .{path},
                        ) catch {},
                        else => stderr.print(
                            "error: --append-system-prompt-file: cannot read {s} ({s}).\n",
                            .{ path, @errorName(err) },
                        ) catch {},
                    }
                    // We already printed a detailed message above, so
                    // return a distinct error tag that main.zig can
                    // recognize and exit cleanly without echoing its
                    // generic "flag value is out of range" line.
                    return error.FlagFileUnreadable;
                };
                options._owned_append_system_prompt = bytes;
                options.append_system_prompt = bytes;
            } else if (std.mem.eql(u8, arg, "--continue")) {
                options.command = .session_continue;
            } else if (std.mem.eql(u8, arg, "--resume") or std.mem.startsWith(u8, arg, "--resume=")) {
                options.command = .session_resume;
                options.subject = try parseFlagValue(argv, &i, arg, "--resume");
            } else {
                return error.UnknownFlag;
            }
        } else if (arg.len == 2 and arg[0] == '-') {
            switch (arg[1]) {
                'c' => {
                    options.command = .session_continue;
                },
                'r' => {
                    if (i + 1 >= argv.len) return error.MissingFlagValue;
                    i += 1;
                    options.command = .session_resume;
                    options.subject = argv[i];
                },
                'h' => {
                    options.command = .help;
                    return options;
                },
                'q' => {
                    options.quiet = true;
                    options.no_spinner = true;
                    options.no_thinking_summary = true;
                },
                // `-v` short form for `--verbose`. Previously fell to
                // the positional branch (dead flag), then produced a
                // confusing "unrecognized subcommand" downstream.
                'v' => options.verbose = true,
                'j' => options.json = true,
                'y' => options.yolo = true,
                'V' => {
                    // Short form for --version. Uppercase so it
                    // doesn't collide with -v (verbose).
                    options.command = .version;
                    return options;
                },
                'm' => {
                    if (i + 1 >= argv.len) return error.MissingFlagValue;
                    i += 1;
                    options.model = argv[i];
                },
                'p' => {
                    if (i + 1 >= argv.len) return error.MissingFlagValue;
                    i += 1;
                    options.provider = argv[i];
                },
                'n' => {
                    // phase-26 daemon-background-11: `-n <name>` session label
                    // at creation (the `--name`/`--name=` forms are handled in
                    // the long-flag chain above).
                    if (i + 1 >= argv.len) return error.MissingFlagValue;
                    i += 1;
                    const value = argv[i];
                    if (value.len == 0) return error.MissingFlagValue;
                    options.name = value;
                    try rejectControlChars("--name", value);
                },
                // Previously: `else => try positional.append(arg)`, so
                // `zcode -x` silently fell through to "unrecognized
                // subcommand" which hid the real mistake. Flag parse
                // errors now stay flag parse errors.
                else => return error.UnknownFlag,
            }
        } else {
            try positional.append(arg);
        }
    }

    if (options.command == .session_continue) {
        if (positional.items.len > 0) {
            options.prompt = try parsePrompt(allocator, positional.items, &options);
        }
        return options;
    }
    if (options.command == .session_resume) {
        return options;
    }

    if (positional.items.len == 0) {
        // sdk-headless-01: `--print` with no positional is still a headless
        // run, not the interactive REPL. This happens when the prompt arrives
        // over `--input-format stream-json` (the stdin NDJSON stream drives the
        // turns) rather than as a CLI argument. Resolve to `.run` with a null
        // prompt; the headless dispatcher reads the prompt from stdin.
        if (options.print) {
            options.command = .run;
            return options;
        }
        options.command = .repl;
        return options;
    }

    const head = positional.items[0];
    if (std.mem.eql(u8, head, "run")) {
        options.command = .run;
        // run/exec are headless one-shot paths; gate SDK flags on them too.
        options.headless = true;
        options.prompt = try parsePrompt(allocator, positional.items[1..], &options);
        return options;
    }
    if (std.mem.eql(u8, head, "version")) {
        options.command = .version;
        return options;
    }
    if (std.mem.eql(u8, head, "exec")) {
        options.command = .exec;
        options.headless = true;
        options.prompt = try parsePrompt(allocator, positional.items[1..], &options);
        return options;
    }
    if (std.mem.eql(u8, head, "completion")) {
        if (positional.items.len < 2) return error.MissingSubcommand;
        options.command = .completion;
        options.subject = positional.items[1]; // bash | zsh | fish
        return options;
    }
    if (std.mem.eql(u8, head, "models")) {
        if (positional.items.len < 2) return error.MissingSubcommand;
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .models_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "test")) {
            options.command = .models_test;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "providers")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode providers - Inspect and log into LLM providers.
                \\
                \\Subcommands:
                \\  status              Print each provider with its configured=true/false
                \\                      and where the key was resolved from (env, keychain,
                \\                      config, default).
                \\  login [provider]    Print the env-var name to export for [provider]
                \\                      (or the default provider when omitted).
                \\  logout [provider]   Print the env-var name to unset.
                \\
                \\Providers are provisioned via either the keychain (`zcode keychain set`)
                \\or a provider-standard env var (ANTHROPIC_API_KEY, OPENAI_API_KEY, ...).
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "login")) {
            options.command = .providers_login;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "logout")) {
            options.command = .providers_logout;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "status")) {
            options.command = .providers_status;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "session")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode session - Manage session history and checkpoints.
                \\
                \\Subcommands:
                \\  list                                   List sessions newest-first.
                \\  resume [id-or-term]                    Resume by id or fuzzy term; no
                \\                                         arg lists sessions to pick from.
                \\  continue ["prompt"]                    Resume the most recent session,
                \\                                         optionally with an opening prompt.
                \\  compact [id]                           Compact the session transcript.
                \\  export <id>                            Print the session bundle as JSON.
                \\  checkpoint <id> [label]                Tag the current state of <id>.
                \\  checkpoints <id>                       List checkpoints for <id>.
                \\  restore <id> [checkpoint]              Restore workspace from a checkpoint.
                \\  share <id> [label]                     Emit a share URL (local daemon).
                \\  import <bundle-json>                   Import a session bundle.
                \\  undo <id> [count]                      Drop the last N turns.
                \\  fork <id> [label]                      Copy <id> into a new session.
                \\  rotate-key                             Rotate the session encryption key.
                \\
                \\Examples:
                \\  zcode session list
                \\  zcode -c "continue where we left off"
                \\  zcode session export <id> > session.json
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .session_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "resume")) {
            // Arg is now optional: `session resume` with no id/term prints the
            // session list with a resume hint (the interactive picker lives in
            // the REPL); `session resume <id-or-term>` resolves exact then fuzzy.
            options.command = .session_resume;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "compact")) {
            if (positional.items.len < 3) return reportUsageError("session compact", "<session-id>", "session compact <session-id>");
            options.command = .session_compact;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "export")) {
            if (positional.items.len < 3) return reportUsageError("session export", "<session-id>", "session export <session-id> [md]");
            options.command = .session_export;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.markdown = std.mem.eql(u8, positional.items[3], "md") or std.mem.eql(u8, positional.items[3], "markdown");
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "checkpoint")) {
            if (positional.items.len < 3) return reportUsageError("session checkpoint", "<session-id>", "session checkpoint <session-id> [label]");
            options.command = .session_checkpoint;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "checkpoints")) {
            if (positional.items.len < 3) return reportUsageError("session checkpoints", "<session-id>", "session checkpoints <session-id>");
            options.command = .session_checkpoints;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "restore")) {
            if (positional.items.len < 3) return reportUsageError("session restore", "<session-id>", "session restore <session-id> <label>");
            if (positional.items.len < 4) return reportUsageError("session restore", "<label>", "session restore <session-id> <label>");
            options.command = .session_restore;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "share")) {
            if (positional.items.len < 3) return reportUsageError("session share", "<session-id>", "session share <session-id> [label]");
            options.command = .session_share;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "import")) {
            if (positional.items.len < 3) return reportUsageError("session import", "<bundle-path>", "session import <bundle-path>");
            options.command = .session_import;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "undo")) {
            if (positional.items.len < 3) return reportUsageError("session undo", "<session-id>", "session undo <session-id>");
            options.command = .session_undo;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "fork")) {
            if (positional.items.len < 3) return reportUsageError("session fork", "<session-id>", "session fork <session-id> [label]");
            options.command = .session_fork;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "rotate-key")) {
            options.command = .session_rotate_key;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "agents")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode agents - Inspect declared sub-agents.
                \\
                \\Subcommands:
                \\  list          List agent definitions in this workspace.
                \\  show <name>   Print the agent frontmatter, tools, and system prompt.
                \\
                \\Agents are defined under .zcode/agents/*.md with YAML frontmatter.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .agents_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "show")) {
            if (positional.items.len < 3) return reportUsageError("agents show", "<name>", "agents show <name>");
            options.command = .agents_show;
            options.subject = positional.items[2];
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "daemon")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode daemon - Local HTTP daemon for session sharing and browser handoff.
                \\
                \\Subcommands:
                \\  start                           Spawn the daemon on 127.0.0.1:<ephemeral>.
                \\                                  Prints pid, port, and a bearer token.
                \\  status                          Show running daemon pid, port, started time.
                \\  stop                            SIGTERM the running daemon and clean up state.
                \\  handoff <session-id> [label]    Publish a one-shot share URL for a session.
                \\
                \\The daemon is scoped to the current user, binds to loopback only, and
                \\requires the printed bearer token on every request. It is session-only -
                \\it dies with the zcode instance that started it. See docs/security/.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "start")) {
            options.command = .daemon_start;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "status")) {
            options.command = .daemon_status;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "stop")) {
            options.command = .daemon_stop;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "handoff")) {
            if (positional.items.len < 3) return reportUsageError("daemon handoff", "<session-id>", "daemon handoff <session-id> [label]");
            options.command = .daemon_handoff;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "serve")) {
            options.command = .daemon_serve;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "kairos")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode kairos - Always-on autonomous background agent (per-project).
                \\
                \\Subcommands:
                \\  start                           Spawn the detached KAIROS process for this repo.
                \\  status                          Show whether KAIROS is running for this repo.
                \\  stop                            SIGTERM the running KAIROS process.
                \\
                \\KAIROS fires this project's scheduled tasks while no interactive REPL is
                \\present, and yields the moment one appears. Disabled by default; runs only
                \\when started. See docs/KAIROS.md.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "start")) {
            options.command = .kairos_start;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "status")) {
            options.command = .kairos_status;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "stop")) {
            options.command = .kairos_stop;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "serve")) {
            // Internal: launched detached by `kairos start`. cwd is passed
            // explicitly so the child operates on the right project.
            options.command = .kairos_serve;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    // phase-26 daemon-background-09/01/10: the detached-session surface.
    // `ps` lists live sessions; `kill <id|pid>` SIGTERMs one and removes its
    // registry file; `logs <id|pid>` dumps a --bg session's captured output.
    if (std.mem.eql(u8, head, "ps")) {
        options.command = .ps;
        return options;
    }
    if (std.mem.eql(u8, head, "kill")) {
        if (positional.items.len < 2) return reportUsageError("kill", "<id|pid>", "kill <id|pid>");
        options.command = .kill;
        options.subject = positional.items[1];
        return options;
    }
    if (std.mem.eql(u8, head, "logs")) {
        if (positional.items.len < 2) return reportUsageError("logs", "<id|pid>", "logs <id|pid>");
        options.command = .logs;
        options.subject = positional.items[1];
        return options;
    }
    if (std.mem.eql(u8, head, "hooks")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode hooks - List declared lifecycle hooks.
                \\
                \\Subcommands:
                \\  list    List hooks registered for this workspace with their
                \\          fingerprints and trust state.
                \\
                \\Hooks are TOML-declared shell commands that fire on specific
                \\events (pre-tool-use, post-tool-use, session-start, etc.).
                \\Trust them explicitly via `zcode trust hook-allow <path>`.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .hooks_list;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "marketplace")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode marketplace - Manage remote plugin/command/agent source registries.
                \\
                \\Subcommands:
                \\  sources                          List configured marketplace sources.
                \\  add <name> <url> [sha256]        Register a new source; SHA-256
                \\                                   optionally pins the index file.
                \\  remove <name>                    Remove a source.
                \\  refresh                          Re-fetch every source index.
                \\
                \\Sources ship agent/plugin/command manifests; entries are only installed
                \\after passing the per-source allow/block trust policy.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "sources")) {
            options.command = .marketplace_sources;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "add")) {
            if (positional.items.len < 3) return reportUsageError("marketplace add", "<name>", "marketplace add <name> <url> [sha256]");
            if (positional.items.len < 4) return reportUsageError("marketplace add", "<url>", "marketplace add <name> <url> [sha256]");
            options.command = .marketplace_add;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "remove")) {
            if (positional.items.len < 3) return reportUsageError("marketplace remove", "<name>", "marketplace remove <name>");
            options.command = .marketplace_remove;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "refresh")) {
            options.command = .marketplace_refresh;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "plugins")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode plugins - Install and manage agent-facing plugins.
                \\
                \\Inspect:
                \\  list                List installed plugins with version + source.
                \\  show <name>         Print plugin manifest details.
                \\  marketplace [name]  Browse available plugins from registered sources.
                \\
                \\Lifecycle:
                \\  install <name>      Install a plugin from a configured marketplace.
                \\  uninstall <name>    Remove an installed plugin.
                \\  update <name>       Reinstall from the marketplace (latest version).
                \\  enable <name>       Turn a plugin on (persists in plugin_settings.json).
                \\  disable <name>      Turn a plugin off without uninstalling it.
                \\  disable-all         Disable every installed plugin.
                \\
                \\Enable/disable accept an optional --scope user|workspace.
                \\Plugins go through the trust allow/block policy before installation.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .plugins_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "show")) {
            if (positional.items.len < 3) return reportUsageError("plugins show", "<name>", "plugins show <name>");
            options.command = .plugins_show;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace")) {
            options.command = .plugins_marketplace;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "install")) {
            if (positional.items.len < 3) return reportUsageError("plugins install", "<name>", "plugins install <name>");
            options.command = .plugins_install;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "uninstall")) {
            if (positional.items.len < 3) return reportUsageError("plugins uninstall", "<name>", "plugins uninstall <name>");
            options.command = .plugins_uninstall;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "update")) {
            if (positional.items.len < 3) return reportUsageError("plugins update", "<name>", "plugins update <name>");
            options.command = .plugins_update;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "enable")) {
            if (positional.items.len < 3) return reportUsageError("plugins enable", "<name>", "plugins enable <name> [--scope user|workspace]");
            options.command = .plugins_enable;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "disable")) {
            if (positional.items.len < 3) return reportUsageError("plugins disable", "<name>", "plugins disable <name> [--scope user|workspace]");
            options.command = .plugins_disable;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "disable-all")) {
            options.command = .plugins_disable_all;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "commands")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode commands - Manage /slash commands available in the REPL.
                \\
                \\Inspect & run:
                \\  list                       List installed slash commands.
                \\  show <name>                Print the command's frontmatter + body.
                \\  run <name> [args]          Invoke a slash command non-interactively.
                \\  marketplace [name]         Browse available commands.
                \\
                \\Lifecycle:
                \\  install <name>             Install from a configured marketplace.
                \\  uninstall <name>            Remove an installed command.
                \\  update <name>              Reinstall from the marketplace.
                \\
                \\Slash commands are markdown files under .claude/commands/ with YAML
                \\frontmatter declaring the allowed tool surface.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .commands_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "show")) {
            if (positional.items.len < 3) return reportUsageError("commands show", "<name>", "commands show <name>");
            options.command = .commands_show;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "run")) {
            if (positional.items.len < 3) return reportUsageError("commands run", "<name>", "commands run <name> [args]");
            options.command = .commands_run;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace")) {
            options.command = .commands_marketplace;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "install")) {
            if (positional.items.len < 3) return reportUsageError("commands install", "<name>", "commands install <name>");
            options.command = .commands_install;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "uninstall")) {
            if (positional.items.len < 3) return reportUsageError("commands uninstall", "<name>", "commands uninstall <name>");
            options.command = .commands_uninstall;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "update")) {
            if (positional.items.len < 3) return reportUsageError("commands update", "<name>", "commands update <name>");
            options.command = .commands_update;
            options.subject = positional.items[2];
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "skills")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode skills - Manage on-demand, user-invocable skill bundles.
                \\
                \\Subcommands:
                \\  list                 List installed skills with name + description.
                \\  show <name>          Print the skill's SKILL.md body.
                \\  run <name> [args]    Invoke a skill in the current session.
                \\
                \\Skills differ from commands: they are loaded lazily on user request,
                \\can include resource files, and are invoked by name (`/skill foo`).
                \\Bundled + installed skills live under .claude/skills/.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .skills_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "show")) {
            if (positional.items.len < 3) return reportUsageError("skills show", "<name>", "skills show <name>");
            options.command = .skills_show;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "run")) {
            if (positional.items.len < 3) return reportUsageError("skills run", "<name>", "skills run <name> [args]");
            options.command = .skills_run;
            options.subject = positional.items[2];
            if (positional.items.len > 3) {
                options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            }
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "skill")) {
        if (positional.items.len < 2) return error.MissingSubcommand;
        options.subject = positional.items[1];
        if (positional.items.len > 2) {
            options.command = .skills_run;
            options.prompt = try parsePrompt(allocator, positional.items[2..], &options);
        } else {
            options.command = .skills_show;
        }
        return options;
    }
    if (std.mem.eql(u8, head, "trust")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode trust - Manage per-workspace / hook / marketplace trust decisions.
                \\
                \\Subcommands:
                \\  status [path]                 Current trust state for path (default: cwd).
                \\  allow <path>                  Grant durable trust to the workspace.
                \\  revoke <path>                 Revoke a prior trust grant.
                \\  hooks                         List trusted hook fingerprints.
                \\  hook-allow <path>             Trust a hook by workspace-relative path.
                \\  hook-revoke <path>            Revoke a prior hook trust grant.
                \\  marketplace                   Show marketplace allow/block state.
                \\  marketplace-allow <prefix>    Add an allowlist prefix for marketplace entries.
                \\  marketplace-block <prefix>    Add a blocklist prefix.
                \\  marketplace-unblock <prefix>  Remove a blocklist prefix.
                \\
                \\Trust decisions are stored under ~/.zcode/trust/.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "status")) {
            options.command = .trust_status;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "allow")) {
            options.command = .trust_allow;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "revoke")) {
            options.command = .trust_revoke;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "hooks")) {
            options.command = .trust_hooks;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "hook-allow")) {
            if (positional.items.len < 3) return reportUsageError("trust hook-allow", "<path>", "trust hook-allow <path>");
            options.command = .trust_hook_allow;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "hook-revoke")) {
            if (positional.items.len < 3) return reportUsageError("trust hook-revoke", "<path>", "trust hook-revoke <path>");
            options.command = .trust_hook_revoke;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace")) {
            options.command = .trust_marketplace;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace-allow")) {
            if (positional.items.len < 3) return reportUsageError("trust marketplace-allow", "<prefix>", "trust marketplace-allow <prefix>");
            options.command = .trust_marketplace_allow;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace-block")) {
            if (positional.items.len < 3) return reportUsageError("trust marketplace-block", "<prefix>", "trust marketplace-block <prefix>");
            options.command = .trust_marketplace_block;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "marketplace-unblock")) {
            options.command = .trust_marketplace_unblock;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "doctor")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode doctor - Run diagnostics.
                \\
                \\Subcommands:
                \\  enterprise    Check enterprise-readiness controls.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "enterprise")) {
            options.command = .doctor_enterprise;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "prompt")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode prompt - Inspect prompt construction.
                \\
                \\Subcommands:
                \\  inspect [--json] [--summary] [--no-packets] [prompt]
                \\                      Render the next prompt packet with diagnostics.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "inspect")) {
            options.command = .prompt_inspect;
            var prompt_start: usize = 2;
            while (prompt_start < positional.items.len) : (prompt_start += 1) {
                const item = positional.items[prompt_start];
                if (std.mem.eql(u8, item, "--summary")) {
                    options.prompt_inspect_summary = true;
                    options.prompt_inspect_include_packets = false;
                    continue;
                }
                if (std.mem.eql(u8, item, "--no-packets")) {
                    options.prompt_inspect_include_packets = false;
                    continue;
                }
                if (std.mem.eql(u8, item, "--json")) {
                    options.json = true;
                    continue;
                }
                break;
            }
            options.prompt = if (prompt_start < positional.items.len)
                try parsePrompt(allocator, positional.items[prompt_start..], &options)
            else
                null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "auth")) {
        if (positional.items.len >= 3 and
            std.mem.eql(u8, positional.items[1], "jwks") and
            std.mem.eql(u8, positional.items[2], "refresh"))
        {
            options.command = .auth_jwks_refresh;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "mcp")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode mcp - Manage Model Context Protocol servers.
                \\
                \\Inspect:
                \\  list                                   Registered servers.
                \\  tools [server]                         Tools exposed by [server] (or all).
                \\  resources [server]                     Resources exposed by [server].
                \\  templates [server]                     Resource templates.
                \\  prompts [server]                       Prompts.
                \\  notifications [server]                 Recent notifications.
                \\
                \\Invoke:
                \\  read <server> <uri>                    Fetch a resource by URI.
                \\  prompt <server> <name> [json-args]     Render a prompt.
                \\  complete <server> <ref> [json-args]    Completion request.
                \\
                \\Subscriptions & logging:
                \\  subscribe <server> <uri>               Subscribe to a resource.
                \\  unsubscribe <server> <uri>             Unsubscribe.
                \\  log-level <server> <level>             Set server log level.
                \\
                \\Registry:
                \\  add <name> <command...>                Register a stdio server.
                \\  remove <name>                          Unregister a server.
                \\  test <name>                            Handshake check.
                \\
                \\Auth (OAuth):
                \\  auth login <server>                    Start the browser OAuth flow.
                \\  auth status <server>                   Show stored token state.
                \\  auth logout <server>                   Delete stored tokens.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "list")) {
            options.command = .mcp_list;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "tools")) {
            options.command = .mcp_tools;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "resources")) {
            options.command = .mcp_resources;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "templates")) {
            options.command = .mcp_templates;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "read")) {
            if (positional.items.len < 3) return reportUsageError("mcp read", "<server>", "mcp read <server> <uri>");
            if (positional.items.len < 4) return reportUsageError("mcp read", "<uri>", "mcp read <server> <uri>");
            options.command = .mcp_read;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "prompts")) {
            options.command = .mcp_prompts;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "prompt")) {
            if (positional.items.len < 3) return reportUsageError("mcp prompt", "<server>", "mcp prompt <server> <name> [json-args]");
            if (positional.items.len < 4) return reportUsageError("mcp prompt", "<name>", "mcp prompt <server> <name> [json-args]");
            options.command = .mcp_prompt;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "complete")) {
            if (positional.items.len < 3) return reportUsageError("mcp complete", "<server>", "mcp complete <server> <ref> <arg> [value]");
            if (positional.items.len < 4) return reportUsageError("mcp complete", "<ref> <arg>", "mcp complete <server> <ref> <arg> [value]");
            options.command = .mcp_complete;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "subscribe")) {
            if (positional.items.len < 3) return reportUsageError("mcp subscribe", "<server>", "mcp subscribe <server> <uri>");
            if (positional.items.len < 4) return reportUsageError("mcp subscribe", "<uri>", "mcp subscribe <server> <uri>");
            options.command = .mcp_subscribe;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "unsubscribe")) {
            if (positional.items.len < 3) return reportUsageError("mcp unsubscribe", "<server>", "mcp unsubscribe <server> <uri>");
            if (positional.items.len < 4) return reportUsageError("mcp unsubscribe", "<uri>", "mcp unsubscribe <server> <uri>");
            options.command = .mcp_unsubscribe;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "log-level")) {
            if (positional.items.len < 3) return reportUsageError("mcp log-level", "<server>", "mcp log-level <server> <level>");
            if (positional.items.len < 4) return reportUsageError("mcp log-level", "<level>", "mcp log-level <server> <level>");
            options.command = .mcp_log_level;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "notifications")) {
            options.command = .mcp_notifications;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "add")) {
            if (positional.items.len < 3) return reportUsageError("mcp add", "<name>", "mcp add <name> <command...>");
            if (positional.items.len < 4) return reportUsageError("mcp add", "<command>", "mcp add <name> <command...>");
            options.command = .mcp_add;
            options.subject = positional.items[2];
            options.prompt = try parsePrompt(allocator, positional.items[3..], &options);
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "remove")) {
            if (positional.items.len < 3) return reportUsageError("mcp remove", "<name>", "mcp remove <name>");
            options.command = .mcp_remove;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "test")) {
            if (positional.items.len < 3) return reportUsageError("mcp test", "<name>", "mcp test <name>");
            options.command = .mcp_test;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "auth")) {
            if (positional.items.len < 3) return error.MissingSubcommand;
            if (std.mem.eql(u8, positional.items[2], "status")) {
                options.command = .mcp_auth_status;
                options.subject = if (positional.items.len > 3) positional.items[3] else null;
                return options;
            }
            if (std.mem.eql(u8, positional.items[2], "login")) {
                if (positional.items.len < 4) return reportUsageError("mcp auth login", "<server>", "mcp auth login <server> [token]");
                options.command = .mcp_auth_login;
                options.subject = positional.items[3];
                if (positional.items.len > 4) {
                    options.prompt = try parsePrompt(allocator, positional.items[4..], &options);
                }
                return options;
            }
            if (std.mem.eql(u8, positional.items[2], "logout")) {
                if (positional.items.len < 4) return reportUsageError("mcp auth logout", "<server>", "mcp auth logout <server>");
                options.command = .mcp_auth_logout;
                options.subject = positional.items[3];
                return options;
            }
            return error.UnknownSubcommand;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "policy")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode policy - Inspect / validate the active approval & tool policy.
                \\
                \\Subcommands:
                \\  show        Print the merged policy as key=value lines.
                \\  validate    Re-parse the policy file and report any errors. Useful
                \\              after editing ~/.zcode/policy/policy.toml.
                \\
                \\Policy drives the approval-mode (tiered-auto|manual|strict) gating,
                \\per-tool risk tiers, destructive-shell blocks, and network allow/deny.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "show")) {
            options.command = .policy_show;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "validate")) {
            options.command = .policy_validate;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "benchmark")) {
        if (positional.items.len < 2) return error.MissingSubcommand;
        if (std.mem.eql(u8, positional.items[1], "run")) {
            options.command = .benchmark_run;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "api")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode api - JSON-lines agent API surface (IDE + script integrations).
                \\
                \\Subcommands:
                \\  schema                     Print the JSON-Schema bundle covering every
                \\                             JSON-lines message the api can emit or accept.
                \\  serve                      Read JSON-lines requests from stdin and write
                \\                             replies to stdout. Used by the VS Code
                \\                             extension and any other IDE integration.
                \\
                \\The API uses the same sandbox/policy layer as the REPL. See
                \\docs/IDE_PROTOCOL.md for the wire format.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "schema")) {
            options.command = .api_schema;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "serve")) {
            options.command = .api_serve;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "review")) {
        options.command = .review;
        if (positional.items.len > 1) {
            options.prompt = try parsePrompt(allocator, positional.items[1..], &options);
        }
        return options;
    }
    if (std.mem.eql(u8, head, "update")) {
        options.command = .update;
        return options;
    }
    if (std.mem.eql(u8, head, "audit")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode audit - Inspect and verify the tamper-evident audit log.
                \\
                \\Subcommands:
                \\  verify [path]   Walk the HMAC chain of an audit log file and report the
                \\                  offending line on break. Default path is today's log in
                \\                  ~/.zcode/logs/. Exit 0 when intact, 1 when broken, 2 when
                \\                  the HMAC key is missing.
                \\
                \\Examples:
                \\  zcode audit verify
                \\  zcode audit verify ~/.zcode/logs/audit-20566.jsonl
                \\
                \\See `docs/security/AUDIT_LOG.md` for the chain model.
                \\
            );
            options.command = .help;
            return options;
        }
        if (std.mem.eql(u8, positional.items[1], "verify")) {
            options.command = .audit_verify;
            options.subject = if (positional.items.len > 2) positional.items[2] else null;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "config")) {
        if (positional.items.len < 2) {
            // `zcode config` with no subcommand prints a local help
            // block listing the group's commands, matching how git
            // handles bare `git remote`. Exit code 0 because this is
            // discovery, not an error.
            try std_io.stdoutWriter().writeAll(
                \\zcode config - Inspect resolved zcode configuration.
                \\
                \\Subcommands:
                \\  show    Print the resolved config as TOML. Secrets are redacted.
                \\          Useful for debugging "why isn't my setting taking effect?".
                \\  path    List every file zcode reads (user config, policy, sessions,
                \\          logs, MCP registry, keybindings, managed config).
                \\  schema  Emit a JSON Schema of every accepted config.toml key
                \\          (type + enum hints) for editor integration.
                \\
                \\Examples:
                \\  zcode config show | less
                \\  zcode config path
                \\  zcode config schema > zcode-config.schema.json
                \\
                \\See `zcode --help` for global flags and exit codes.
                \\
            );
            options.command = .help;
            return options;
        }
        const sub = positional.items[1];
        if (std.mem.eql(u8, sub, "show")) {
            options.command = .config_show;
            return options;
        }
        if (std.mem.eql(u8, sub, "path")) {
            options.command = .config_path;
            return options;
        }
        if (std.mem.eql(u8, sub, "schema")) {
            options.command = .config_schema;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "keychain")) {
        if (positional.items.len < 2) {
            try std_io.stdoutWriter().writeAll(
                \\zcode keychain - Provision provider API keys in the OS keychain.
                \\
                \\Subcommands:
                \\  set <provider> <secret>   Store a secret for <provider>. Overwrites.
                \\  get <provider>            Print the stored secret to stdout. Avoid in
                \\                            shared terminals; pipe to another tool only.
                \\  delete <provider>         Remove the stored secret. No-op if absent.
                \\  list                      List provisioned providers (no secrets).
                \\
                \\Providers: openai, openai-compatible, anthropic, gemini, deepseek,
                \\groq, openrouter, azure.
                \\
                \\Examples:
                \\  zcode keychain set anthropic sk-ant-...
                \\  zcode keychain list
                \\  zcode keychain delete anthropic
                \\
                \\Resolution order at runtime: env var (e.g. ANTHROPIC_API_KEY) >
                \\keychain entry > plaintext config. Move keys out of plaintext
                \\config to silence the startup warning.
                \\
            );
            options.command = .help;
            return options;
        }
        const sub = positional.items[1];
        if (std.mem.eql(u8, sub, "set")) {
            if (positional.items.len < 3) return reportUsageError("keychain set", "<provider>", "keychain set <provider> <secret>");
            if (positional.items.len < 4) return reportUsageError("keychain set", "<secret>", "keychain set <provider> <secret>");
            // Reject stray extra args rather than silently joining them
            // with spaces. `keychain set openai sk-abc def` would
            // otherwise store the mangled secret "sk-abc def" under
            // the label "Stored secret" and the next provider call
            // would fail auth. Single-arg secret only - operators
            // should quote keys that contain whitespace.
            if (positional.items.len > 4) {
                const stderr = std_io.stderrWriter();
                stderr.writeAll(
                    "error: keychain set: too many arguments. Quote the secret if it contains spaces.\n" ++
                        "  Usage: zcode keychain set <provider> <secret>\n",
                ) catch {};
                return error.UsageErrorReported;
            }
            options.command = .keychain_set;
            options.subject = positional.items[2];
            options.prompt = positional.items[3];
            return options;
        }
        if (std.mem.eql(u8, sub, "get")) {
            if (positional.items.len < 3) return reportUsageError("keychain get", "<provider>", "keychain get <provider>");
            options.command = .keychain_get;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, sub, "delete") or std.mem.eql(u8, sub, "rm")) {
            if (positional.items.len < 3) return reportUsageError("keychain delete", "<provider>", "keychain delete <provider>");
            options.command = .keychain_delete;
            options.subject = positional.items[2];
            return options;
        }
        if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "ls")) {
            options.command = .keychain_list;
            return options;
        }
        return error.UnknownSubcommand;
    }
    if (std.mem.eql(u8, head, "help")) {
        options.command = .help;
        return options;
    }

    // sdk-headless-01: `--print "<prompt>"` with a bare positional that is
    // not a recognized subcommand routes into the existing one-shot `run`
    // execution. The output-format dispatcher (sdk-headless-02) keys off
    // options.output_format when present; until that lands, --print always
    // resolves to .run and the stored output_format is carried through.
    if (options.print) {
        options.command = .run;
        options.prompt = try parsePrompt(allocator, positional.items, &options);
        return options;
    }

    return error.UnknownCommand;
}

fn parseFlagValue(argv: []const []const u8, index: *usize, arg: []const u8, flag_name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq_idx| {
        const val = arg[eq_idx + 1 ..];
        if (val.len == 0) {
            std.log.warn("flag {s} has empty value", .{flag_name});
            return error.MissingFlagValue;
        }
        return val;
    }

    if (index.* + 1 >= argv.len) return error.MissingFlagValue;
    index.* += 1;
    const value = argv[index.*];
    if (std.mem.startsWith(u8, value, "--")) {
        std.log.warn("flag {s} missing value (got another flag)", .{flag_name});
        return error.MissingFlagValue;
    }
    return value;
}

/// Reject a flag value that contains C0 control bytes or DEL. These
/// never belong in identifier-style flag values (`--model`,
/// `--provider`, `--sandbox`, `--approval-mode`, `--cwd`, ...) and a
/// value with an embedded newline / ANSI escape corrupts log output
/// and can smuggle secondary lines into tsv/jsonl sinks. Applied
/// only to identifier-style flags; prose flags like
/// `--append-system-prompt` legitimately contain newlines and are
/// handled by their own length cap (pass 49).
fn rejectControlChars(flag_name: []const u8, value: []const u8) !void {
    for (value, 0..) |c, idx| {
        if (c < 0x20 or c == 0x7f) {
            std_io.stderrWriter().print(
                "error: {s}: value contains a control character (byte 0x{x:0>2} at offset {d}).\n  - Remove newlines, ANSI escapes, and other control bytes from flag values.\n",
                .{ flag_name, c, idx },
            ) catch {};
            return error.FlagValueTooLarge;
        }
    }
}

fn parsePrompt(allocator: std.mem.Allocator, prompt_parts: []const []const u8, options: *CliOptions) ![]const u8 {
    if (prompt_parts.len == 0) return error.MissingPrompt;
    if (prompt_parts.len == 1) return prompt_parts[0];

    const owned = try std.mem.join(allocator, " ", prompt_parts);
    options._owned_prompt = owned;
    return owned;
}

/// Emit a targeted "error: <cmd>: missing <arg>. Usage: <usage>" line to
/// stderr and signal that a human-readable usage error has already been
/// reported. The top-level main.zig catches this error and exits 2
/// without printing its generic "missing subcommand" fallback, so the
/// user sees only the specific, actionable message. Used by per-
/// subcommand required-positional-arg checks that would otherwise
/// surface as `error.MissingToolArg` / `error.MissingMcpServer` stack
/// traces deep inside the command dispatcher.
fn reportUsageError(cmd: []const u8, missing: []const u8, usage: []const u8) error{UsageErrorReported} {
    const stderr = std_io.stderrWriter();
    stderr.print("error: {s}: missing {s}\n  Usage: zcode {s}\n", .{ cmd, missing, usage }) catch {};
    return error.UsageErrorReported;
}

pub fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\zcode - Enterprise coding agent CLI
        \\
        \\Getting started (60 seconds):
        \\  1. Provision a provider key:  zcode keychain set anthropic <your-key>
        \\  2. Try a one-shot prompt:     zcode run "list Zig files in src/"
        \\  3. Start an interactive session: zcode
        \\  4. Machine-readable output:   zcode exec --json "<prompt>" | jq .
        \\  5. Install shell completion:  zcode completion zsh > ~/.zfunc/_zcode
        \\
        \\Usage:
        \\  zcode                            Start interactive session
        \\  zcode --continue                 Resume most recent session
        \\  zcode -c "prompt"                Resume latest session with initial prompt
        \\  zcode --resume <id>              Resume session by ID
        \\  zcode version                    Print version
        \\  zcode run "<prompt>"             Run one-shot prompt
        \\  zcode exec --json "<prompt>"     Run one-shot and emit JSON
        \\  zcode models list|test [model]
        \\  zcode agents list|show [name]
        \\  zcode hooks list
        \\  zcode marketplace sources|add|remove|refresh [name] [url] [sha256]
        \\  zcode plugins list|show|marketplace [name]
        \\  zcode plugins install|uninstall|update <name>
        \\  zcode commands list|show|run|marketplace [name]
        \\  zcode commands install|uninstall|update <name>
        \\  zcode skills list|show|run [name]
        \\  zcode skill <name> [args]
        \\  zcode trust status|allow|revoke [path]
        \\  zcode trust hooks|hook-allow|hook-revoke [path]
        \\  zcode trust marketplace|marketplace-allow|marketplace-block|marketplace-unblock [prefix]
        \\  zcode doctor enterprise [--json]
        \\  zcode prompt inspect [--json] [--summary] [--no-packets] [prompt]
        \\  zcode auth jwks refresh
        \\  zcode providers login|logout|status [provider]
        \\  zcode session list|resume|compact [session_id]
        \\  zcode session export|checkpoint|checkpoints|restore|share|import|undo|fork [session_id|bundle]
        \\  zcode daemon start|status|stop
        \\  zcode daemon handoff <session_id> [label]
        \\  zcode mcp list|tools|resources|prompts|add|remove|test [server]
        \\  zcode mcp read <server> <uri>
        \\  zcode mcp prompt <server> <name> [json-args]
        \\  zcode mcp auth login|status|logout [server]
        \\  zcode policy show|validate
        \\  zcode api schema|serve
        \\  zcode review [working|commit <sha>|branch <base>]
        \\  zcode update                     Check for updates and self-update
        \\  zcode benchmark run
        \\Flags:
        \\  -m, --model <id>
        \\  -p, --provider <name>
        \\  -n, --name <name>               Name this session (shown in zcode ps and session list)
        \\      --agent <name>
        \\      --profile <name>
        \\      --approval-mode <mode>      tiered-auto (default) | manual | strict
        \\      --sandbox <profile>         read-only | workspace-write | no-network | danger-full-access
        \\      --cwd <path>
        \\  -j, --json                      Emit a single JSON object on stdout (machine-readable mode)
        \\      --print                     Run one prompt non-interactively and exit (headless).
        \\                                  No short alias: -p stays bound to --provider in zcode,
        \\                                  a deliberate divergence from Claude Code's -p, --print.
        \\      --output-format <fmt>       text | json | stream-json (headless; honored with --print/run/exec)
        \\      --input-format <fmt>        text | stream-json (headless; honored with --print/run/exec)
        \\      --max-turns <n>             Cap tool-call rounds (headless); exceeding emits error_max_turns
        \\      --max-budget-usd <x>        Cap estimated spend in USD (headless)
        \\      --json-schema <schema|@file>  Constrain output to a JSON schema (headless)
        \\      --fork-session              Fork the resumed session before running (headless)
        \\      --thinking | --max-thinking-tokens <n>  Set reserved reasoning-token budget (headless)
        \\      --include-partial-messages  Emit per-chunk stream_event messages (stream-json; headless)
        \\      --include-hook-events       Emit hook-lifecycle system events (stream-json; headless)
        \\      --replay-user-messages      Re-emit accepted user messages on stdout (stream-json; headless)
        \\  -V, --version                   Print version and exit
        \\      --no-color                  Disable ANSI colors (also honors the NO_COLOR env var)
        \\      --no-fullscreen
        \\      --no-spinner
        \\      --no-thinking-summary
        \\      --no-stream
        \\      --preprocessor | --no-preprocessor
        \\      --preprocessor-provider <name>
        \\      --preprocessor-model <id|provider/id>
        \\      --preprocessor-base-url <url>
        \\      --preprocessor-api-key <key>
        \\      --preprocessor-max-output-tokens <n>
        \\      --prompt-label <text>
        \\      --transcript-max-lines <n>
        \\      --append-system-prompt <text>         Inline text appended to system prompt for this run
        \\      --append-system-prompt-file <path>    Read append-system-prompt from a file
        \\      --strict
        \\      --approve-high
        \\  -y, --yolo                      Auto-approve high-risk tool calls (use with care)
        \\  -v, --verbose                   Log extra diagnostic info to stderr
        \\  -q, --quiet                     Suppress non-essential output (spinner, thinking summary)
        \\      --log-level <level>         debug | info | warn (default) | error
        \\      --log-format <text|json>    Log format on stderr (json is aggregator-friendly)
        \\      --accessible                Screen-reader friendly: no color, no spinner, no fullscreen, no reasoning-summary animation
        \\      --list-env                  Print every environment variable zcode reads, with current value (secrets redacted)
        \\  -c, --continue                  Resume most recent session
        \\  -r, --resume <id>               Resume specific session by ID
        \\
        \\Exit codes:
        \\  0    Success.
        \\  1    Runtime error (provider failure, tool error, non-config problem).
        \\  2    Invalid configuration, flags, or arguments; strict-mode violation.
        \\  130  Interrupted by user (SIGINT / Ctrl+C).
        \\
    );
}

const testing = std.testing;

test "parse run command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "run", "fix", "the", "tests" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("fix the tests", opts.prompt.?);
}

test "parse --print routes a bare prompt into the one-shot run path" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "hello" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.print);
    try testing.expect(opts.headless);
    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("hello", opts.prompt.?);
}

test "parse -p stays bound to --provider (no --print collision)" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "-p", "openai", "exec", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("openai", opts.provider.?);
    try testing.expect(opts.command == .exec);
    try testing.expect(!opts.print);
    try testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parse --print --output-format json sets the headless gate and format" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "--output-format", "json", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.print);
    try testing.expect(opts.headless);
    try testing.expectEqualStrings("json", opts.output_format.?);
    try testing.expectEqualStrings("hi", opts.prompt.?);
}

test "parse --print -- with a dash-prefixed prompt is taken literally" {
    // The `--` separator must still hold under --print so a prompt that
    // looks like a flag is not misread (Task A risk note).
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "--", "--literally-a-prompt" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("--literally-a-prompt", opts.prompt.?);
}

test "parse enterprise doctor and jwks refresh commands" {
    const allocator = testing.allocator;

    var doctor = try parse(allocator, &.{ "doctor", "enterprise", "--json" });
    defer doctor.deinit(allocator);
    try testing.expect(doctor.command == .doctor_enterprise);
    try testing.expect(doctor.json);

    var refresh = try parse(allocator, &.{ "auth", "jwks", "refresh" });
    defer refresh.deinit(allocator);
    try testing.expect(refresh.command == .auth_jwks_refresh);
}

test "parse prompt inspect command" {
    const allocator = testing.allocator;

    var opts = try parse(allocator, &.{ "prompt", "inspect", "--json", "fix", "tests" });
    defer opts.deinit(allocator);
    try testing.expect(opts.command == .prompt_inspect);
    try testing.expect(opts.json);
    try testing.expectEqualStrings("fix tests", opts.prompt.?);
}

test "parse prompt inspect summary without prompt packets" {
    const allocator = testing.allocator;

    var opts = try parse(allocator, &.{ "prompt", "inspect", "--summary", "--no-packets", "fix", "tests" });
    defer opts.deinit(allocator);
    try testing.expect(opts.command == .prompt_inspect);
    try testing.expect(opts.prompt_inspect_summary);
    try testing.expect(!opts.prompt_inspect_include_packets);
    try testing.expectEqualStrings("fix tests", opts.prompt.?);
}

test "double-dash stops option parsing for run prompt" {
    // Without the separator, "--help" would be captured as the --help
    // command. With it, everything after "--" is literal prompt text so
    // the user can pass text that happens to start with a dash.
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "run", "--", "--literally", "in", "the", "prompt" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("--literally in the prompt", opts.prompt.?);
}

test "parse --append-system-prompt captures inline text" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--append-system-prompt", "Always use TDD", "run", "fix", "bug" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("Always use TDD", opts.append_system_prompt.?);
    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("fix bug", opts.prompt.?);
}

test "parse --append-system-prompt-file reads file contents" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "style.md", .data = "Follow Elizabeth style guide.\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(cwd);
    const file_path = try std.fs.path.join(allocator, &.{ cwd, "style.md" });
    defer allocator.free(file_path);

    const argv = [_][]const u8{ "--append-system-prompt-file", file_path, "run", "refactor" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("Follow Elizabeth style guide.\n", opts.append_system_prompt.?);
}

test "parse --append-system-prompt-file on missing file errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--append-system-prompt-file", "/nonexistent/path/zcode-test-missing.md", "run", "x" };
    // Surfaces as FlagFileUnreadable now (the parser prints a
    // targeted stderr message first, then returns this distinct
    // tag so main can skip the generic catch-block formatting).
    try testing.expectError(error.FlagFileUnreadable, parse(allocator, argv[0..]));
}

test "double-dash does not consume dashes that come before it" {
    // Flags before the separator still parse normally, so the user
    // can combine knobs with a dash-leading prompt in one invocation.
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--no-color", "run", "--", "--force", "migration" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.no_color);
    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("--force migration", opts.prompt.?);
}

test "bare double-dash is stripped from positionals" {
    // The standalone "--" token itself must not leak into the prompt --
    // POSIX says it's a separator, not a word.
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "run", "--", "literal" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("literal", opts.prompt.?);
}

test "parse nested subcommand" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "resume", "abc123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_resume);
    try testing.expectEqualStrings("abc123", opts.subject.?);
}

test "parse benchmark command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "benchmark", "run" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .benchmark_run);
}

test "parse version command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"version"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .version);
}

test "parse version flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"--version"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .version);
}

test "parse session export command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "export", "abc123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_export);
    try testing.expectEqualStrings("abc123", opts.subject.?);
}

test "parse mcp tools command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "tools", "demo" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_tools);
    try testing.expectEqualStrings("demo", opts.subject.?);
}

test "parse mcp resources command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "resources", "figma" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_resources);
    try testing.expectEqualStrings("figma", opts.subject.?);
}

test "parse mcp read command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "read", "figma", "figma://file/123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_read);
    try testing.expectEqualStrings("figma", opts.subject.?);
    try testing.expectEqualStrings("figma://file/123", opts.prompt.?);
}

test "parse session compact without id reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "compact" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse session export without id reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "export" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse session restore without label reports usage error" {
    const allocator = testing.allocator;
    // Has session id but no label -- historically reached the handler
    // and surfaced a cryptic runtime error.
    const argv = [_][]const u8{ "session", "restore", "abc123" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse session import without bundle reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "import" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse daemon handoff without session id reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "daemon", "handoff" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse mcp read without uri reports usage error" {
    const allocator = testing.allocator;
    // Missing URI (only `mcp read <server>` provided).
    const argv = [_][]const u8{ "mcp", "read", "figma" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse mcp read without server reports usage error" {
    const allocator = testing.allocator;
    // Only `mcp read` with no positional server argument -- historically
    // fell through to a runtime error.MissingMcpServer deep inside the
    // MCP client. Parser catches it now.
    const argv = [_][]const u8{ "mcp", "read" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse mcp remove without name reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "remove" };
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse mcp prompt command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "prompt", "figma", "get_design_context", "{\"nodeId\":\"123\"}" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_prompt);
    try testing.expectEqualStrings("figma", opts.subject.?);
    try testing.expectEqualStrings("get_design_context {\"nodeId\":\"123\"}", opts.prompt.?);
}

test "parse mcp add command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "add", "figma", "https://mcp.figma.com/mcp" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_add);
    try testing.expectEqualStrings("figma", opts.subject.?);
    try testing.expectEqualStrings("https://mcp.figma.com/mcp", opts.prompt.?);
}

test "parse agents show command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "agents", "show", "reviewer" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .agents_show);
    try testing.expectEqualStrings("reviewer", opts.subject.?);
}

test "parse marketplace add command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "marketplace", "add", "official", "https://example.com/catalog.json", "abcd" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .marketplace_add);
    try testing.expectEqualStrings("official", opts.subject.?);
    try testing.expectEqualStrings("https://example.com/catalog.json abcd", opts.prompt.?);
}

test "parse review command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "review", "commit", "abc123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .review);
    try testing.expectEqualStrings("commit abc123", opts.prompt.?);
}

test "parse plugins show command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "plugins", "show", "demo" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .plugins_show);
    try testing.expectEqualStrings("demo", opts.subject.?);
}

test "parse skills run command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "skills", "run", "debug", "provider", "auth" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .skills_run);
    try testing.expectEqualStrings("debug", opts.subject.?);
    try testing.expectEqualStrings("provider auth", opts.prompt.?);
}

test "parse singular skill command as show" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "skill", "debug" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .skills_show);
    try testing.expectEqualStrings("debug", opts.subject.?);
}

test "parse commands run command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "commands", "run", "review", "src/main.zig", "fast" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .commands_run);
    try testing.expectEqualStrings("review", opts.subject.?);
    try testing.expectEqualStrings("src/main.zig fast", opts.prompt.?);
}

test "parse mcp auth login command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "mcp", "auth", "login", "demo", "secret-token" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .mcp_auth_login);
    try testing.expectEqualStrings("demo", opts.subject.?);
    try testing.expectEqualStrings("secret-token", opts.prompt.?);
}

test "parse session checkpoint command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "checkpoint", "abc123", "pre", "release" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_checkpoint);
    try testing.expectEqualStrings("abc123", opts.subject.?);
    try testing.expectEqualStrings("pre release", opts.prompt.?);
}

test "parse session fork command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "fork", "abc123", "release", "candidate" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_fork);
    try testing.expectEqualStrings("abc123", opts.subject.?);
    try testing.expectEqualStrings("release candidate", opts.prompt.?);
}

test "parse session restore command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "session", "restore", "abc123", "pre-release" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_restore);
    try testing.expectEqualStrings("abc123", opts.subject.?);
    try testing.expectEqualStrings("pre-release", opts.prompt.?);
}

test "parse daemon handoff command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "daemon", "handoff", "abc123", "editor", "share" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .daemon_handoff);
    try testing.expectEqualStrings("abc123", opts.subject.?);
    try testing.expectEqualStrings("editor share", opts.prompt.?);
}

test "parse trust hook allow command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "trust", "hook-allow", ".zcode/hooks/pre-tool-use.sh" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .trust_hook_allow);
    try testing.expectEqualStrings(".zcode/hooks/pre-tool-use.sh", opts.subject.?);
}

test "parse plugins marketplace command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "plugins", "marketplace", "review-plus" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .plugins_marketplace);
    try testing.expectEqualStrings("review-plus", opts.subject.?);
}

test "parse commands install command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "commands", "install", "triage" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .commands_install);
    try testing.expectEqualStrings("triage", opts.subject.?);
}

test "parse api serve command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "api", "serve" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .api_serve);
}

test "parse agent flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--agent", "reviewer", "run", "check", "it" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("reviewer", opts.agent.?);
}

test "parse ui override flags" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{
        "--no-fullscreen",
        "--no-spinner",
        "--no-thinking-summary",
        "--no-stream",
        "--prompt-label",
        "zc>",
        "--transcript-max-lines",
        "1500",
        "run",
        "hello",
    };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expect(opts.no_fullscreen);
    try testing.expect(opts.no_spinner);
    try testing.expect(opts.no_thinking_summary);
    try testing.expect(opts.no_stream);
    try testing.expectEqualStrings("zc>", opts.prompt_label.?);
    try testing.expectEqual(@as(usize, 1500), opts.transcript_max_lines.?);
}

test "parse preprocessor override flags" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{
        "--preprocessor",
        "--preprocessor-provider",
        "openrouter",
        "--preprocessor-model",
        "anthropic/claude-sonnet-4",
        "--preprocessor-base-url",
        "https://openrouter.example.test/api/v1",
        "--preprocessor-api-key",
        "sk-pre",
        "--preprocessor-max-output-tokens",
        "420",
        "run",
        "hello",
    };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expectEqual(@as(?bool, true), opts.preprocessor_enabled);
    try testing.expectEqualStrings("openrouter", opts.preprocessor_provider.?);
    try testing.expectEqualStrings("anthropic/claude-sonnet-4", opts.preprocessor_model.?);
    try testing.expectEqualStrings("https://openrouter.example.test/api/v1", opts.preprocessor_base_url.?);
    try testing.expectEqualStrings("sk-pre", opts.preprocessor_api_key.?);
    try testing.expectEqual(@as(usize, 420), opts.preprocessor_max_output_tokens.?);
}

test "parse yolo flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--yolo", "run", "do", "it" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .run);
    try testing.expect(opts.yolo);
    try testing.expectEqualStrings("do it", opts.prompt.?);
}

test "parse --continue flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"--continue"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_continue);
    try testing.expect(opts.prompt == null);
}

test "parse -c flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"-c"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_continue);
    try testing.expect(opts.prompt == null);
}

test "parse -c with prompt" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "-c", "fix", "the", "bug" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_continue);
    try testing.expectEqualStrings("fix the bug", opts.prompt.?);
}

test "parse --resume with session id" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--resume", "abc123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_resume);
    try testing.expectEqualStrings("abc123", opts.subject.?);
}

test "parse --resume= with session id" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"--resume=abc123"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_resume);
    try testing.expectEqualStrings("abc123", opts.subject.?);
}

test "parse -r with session id" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "-r", "abc123" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.command == .session_resume);
    try testing.expectEqualStrings("abc123", opts.subject.?);
}

// ── settings-05: --setting-sources scope filtering ─────────────────

test "settings-05: --setting-sources user,project parses two scopes" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--setting-sources", "user,project" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    const s = opts.setting_sources.?;
    try testing.expect(s.user);
    try testing.expect(s.project);
    try testing.expect(!s.local);
}

test "settings-05: --setting-sources=local parses local-only" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"--setting-sources=local"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    const s = opts.setting_sources.?;
    try testing.expect(!s.user);
    try testing.expect(!s.project);
    try testing.expect(s.local);
}

test "settings-05: --setting-sources unknown token errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--setting-sources", "user,bogus" };
    try testing.expectError(error.InvalidSettingSource, parse(allocator, argv[0..]));
}

test "settings-05: setting_sources null when flag absent" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "run", "hello" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.setting_sources == null);
}

// ── sdk-headless-14: headless gating flags ─────────────────────────

test "sdk-headless-14: --max-turns parses an integer and sets the headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-turns", "5", "--print", "hello" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqual(@as(?usize, 5), opts.max_turns);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --max-turns=N equals form parses" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-turns=3", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqual(@as(?usize, 3), opts.max_turns);
}

test "sdk-headless-14: --max-turns abc errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-turns", "abc" };
    try testing.expectError(error.InvalidCharacter, parse(allocator, argv[0..]));
}

test "sdk-headless-14: --max-turns 0 errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-turns", "0" };
    try testing.expectError(error.InvalidFlagValue, parse(allocator, argv[0..]));
}

test "sdk-headless-14: --max-budget-usd parses a float and sets the headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-budget-usd", "1.50", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.max_budget_usd != null);
    try testing.expectApproxEqAbs(@as(f64, 1.50), opts.max_budget_usd.?, 1e-9);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --max-budget-usd abc errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-budget-usd", "abc" };
    try testing.expectError(error.InvalidFlagValue, parse(allocator, argv[0..]));
}

test "sdk-headless-14: --json-schema inline sets the field and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--json-schema", "{\"type\":\"object\"}", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("{\"type\":\"object\"}", opts.json_schema.?);
    try testing.expect(opts._owned_json_schema == null);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --json-schema @file reads file contents" {
    const allocator = testing.allocator;
    const test_helpers = @import("../core/test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "schema.json", .data = "{\"type\":\"array\"}" });
    const abs_path = try test_helpers.tmpDirPath(allocator, &tmp, "schema.json");
    defer allocator.free(abs_path);
    const file_arg = try std.fmt.allocPrint(allocator, "@{s}", .{abs_path});
    defer allocator.free(file_arg);

    const argv = [_][]const u8{ "--json-schema", file_arg };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("{\"type\":\"array\"}", opts.json_schema.?);
    try testing.expect(opts._owned_json_schema != null);
}

test "sdk-headless-14: --json-schema @missing-file errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--json-schema", "@/no/such/schema/file.json" };
    try testing.expectError(error.FlagFileUnreadable, parse(allocator, argv[0..]));
}

test "sdk-headless-14: --fork-session sets the flag and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--fork-session", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.fork_session);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --max-thinking-tokens parses an integer" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--max-thinking-tokens", "2048", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqual(@as(?usize, 2048), opts.max_thinking_tokens);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: bare --thinking sets the headless gate without consuming the prompt" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--thinking", "run", "hello" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    // Bare --thinking must NOT swallow "run" as its value.
    try testing.expect(opts.command == .run);
    try testing.expectEqualStrings("hello", opts.prompt.?);
    try testing.expect(opts.max_thinking_tokens == null);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --thinking=N parses an explicit cap" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--thinking=512", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqual(@as(?usize, 512), opts.max_thinking_tokens);
}

test "sdk-headless-14: --permission-prompt-tool sets the field and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--permission-prompt-tool", "mcp__authz__check", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("mcp__authz__check", opts.permission_prompt_tool.?);
    try testing.expect(opts.headless);
}

test "sdk-headless-14: --permission-prompt-tool=NAME equals form parses" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--permission-prompt-tool=mcp__authz__check", "--print", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expectEqualStrings("mcp__authz__check", opts.permission_prompt_tool.?);
    try testing.expect(opts.headless);
}

// ── sdk-headless-12: partial-message / hook-event / user-replay flags ──

test "sdk-headless-12: --include-partial-messages sets the flag and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "--include-partial-messages", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.include_partial_messages);
    try testing.expect(!opts.include_hook_events);
    try testing.expect(!opts.replay_user_messages);
    try testing.expect(opts.headless);
}

test "sdk-headless-12: --include-hook-events sets the flag and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "--include-hook-events", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.include_hook_events);
    try testing.expect(!opts.include_partial_messages);
    try testing.expect(opts.headless);
}

test "sdk-headless-12: --replay-user-messages sets the flag and headless gate" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--print", "--replay-user-messages", "hi" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.replay_user_messages);
    try testing.expect(opts.headless);
}

test "sdk-headless-12: the three flags compose in one invocation" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{
        "--print",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--include-hook-events",
        "--replay-user-messages",
        "hi",
    };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);

    try testing.expect(opts.include_partial_messages);
    try testing.expect(opts.include_hook_events);
    try testing.expect(opts.replay_user_messages);
    try testing.expect(opts.headless);
    try testing.expectEqualStrings("stream-json", opts.output_format.?);
}

// phase-26 daemon-background-01/09/10: ps/kill/logs + --bg parsing.

test "parse ps resolves to .ps command" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"ps"};
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expect(opts.command == .ps);
}

test "parse kill with id sets .kill and subject" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "kill", "1234" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expect(opts.command == .kill);
    try testing.expectEqualStrings("1234", opts.subject.?);
}

test "parse kill without an id reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"kill"};
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse logs with id sets .logs and subject" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "logs", "abc" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expect(opts.command == .logs);
    try testing.expectEqualStrings("abc", opts.subject.?);
}

test "parse logs without an id reports usage error" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{"logs"};
    try testing.expectError(error.UsageErrorReported, parse(allocator, argv[0..]));
}

test "parse --bg sets the bg flag" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--bg", "run", "do a thing" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expect(opts.bg);
    try testing.expect(opts.command == .run);
}

test "parse --background is an alias for --bg" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--background", "run", "do a thing" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expect(opts.bg);
}

// phase-26 daemon-background-11: -n / --name session label at creation.

test "parse -n sets the session name" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "-n", "foo", "run", "do a thing" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expectEqualStrings("foo", opts.name.?);
}

test "parse --name sets the session name" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--name", "foo", "run", "do a thing" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expectEqualStrings("foo", opts.name.?);
}

test "parse --name=foo sets the session name" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--name=foo", "run", "do a thing" };
    var opts = try parse(allocator, argv[0..]);
    defer opts.deinit(allocator);
    try testing.expectEqualStrings("foo", opts.name.?);
}

test "parse --name= with an empty value errors" {
    const allocator = testing.allocator;
    const argv = [_][]const u8{ "--name=", "run", "do a thing" };
    try testing.expectError(error.MissingFlagValue, parse(allocator, argv[0..]));
}
