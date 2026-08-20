const std = @import("std");
const std_io = @import("core/std_io.zig");
const rt = @import("zcode_runtime");
const clock = @import("core/clock.zig");
const builtin = @import("builtin");
const build_options = @import("build_options");

const repl = @import("cli/repl.zig");
const agents_mod = @import("core/agents.zig");
const commands_mod = @import("core/commands.zig");
const config_mod = @import("core/config.zig");
const agent_color_mod = @import("core/agent_color.zig");
const effort_level_mod = @import("core/effort_level.zig");
const ui_theme = @import("core/ui_theme.zig");
const cost_mod = @import("core/cost.zig");
const memory_mod = @import("core/memory.zig");
const hooks_mod = @import("core/hooks.zig");
const output_styles_mod = @import("core/output_styles.zig");
const marketplace_mod = @import("core/marketplace.zig");
const plugins_mod = @import("core/plugins.zig");
const lsp_manager = @import("core/lsp/manager.zig");
const security_mod = @import("core/security.zig");
const platform_mod = @import("core/platform.zig");
const todos_mod = @import("core/todos.zig");
const onboarding_mod = @import("core/onboarding.zig");
const instructions_mod = @import("core/instructions.zig");
const parse_helpers = @import("core/parse_helpers.zig");
const format_mod = @import("core/format.zig");
const skills_mod = @import("core/skills.zig");
const git_ref = @import("core/git_ref.zig");
const git_fs = @import("core/git_fs.zig");
const git_extra = @import("tools/git_extra.zig");
const skill_usage_mod = @import("core/skill_usage.zig");
const arg_sub = @import("core/argument_substitution.zig");
const trust_mod = @import("core/trust.zig");
const compaction_mod = @import("core/compaction.zig");
const config_parse = @import("core/config_parse.zig");
const types = @import("core/types.zig");
const providers = @import("providers/mod.zig");
const policy_mod = @import("policy/policy.zig");
const mcp_client = @import("mcp/client.zig");
const agent_runtime = @import("agent_runtime.zig");
const session_store_mod = @import("session/store.zig");
const review_flow = @import("review_flow.zig");
const session_bundles = @import("session/bundles.zig");
const update_mod = @import("update.zig");
const tool_helpers = @import("tools/helpers.zig");
const team_tool = @import("tools/team.zig");
const task_mod = @import("tools/task.zig");
const workspace_dirs_mod = @import("core/workspace_dirs.zig");
const stats_report = @import("core/stats_report.zig");
const ide_detect = @import("core/ide_detect.zig");
const terminal_caps = @import("core/terminal_caps.zig");
const heap_diag = @import("core/heap_diag.zig");
const ctx_viz = @import("core/ctx_viz.zig");
const permission_rules_mod = @import("core/permission_rules.zig");
const permission_rule_string_mod = @import("core/permission_rule_string.zig");
const permission_reason_mod = @import("core/permission_reason.zig");
const shadow_detection_mod = @import("core/shadow_detection.zig");
const permission_decision_mod = @import("core/permission_decision.zig");
const which_mod = @import("core/which.zig");
const ripgrep_status = @import("core/ripgrep_status.zig");
const sandbox_mod = @import("core/sandbox.zig");
const keychain_mod = @import("core/keychain.zig");
const feature_gates_mod = @import("core/feature_gates.zig");
const command_canonical = @import("core/command_canonical.zig");
const cc_stub_commands = @import("core/cc_stub_commands.zig");
const removed_commands = @import("core/removed_commands.zig");
const model_alias = @import("core/model_alias.zig");
const model_allowlist = @import("core/model_allowlist.zig");
const deprecation = @import("core/deprecation.zig");
const shell_completion = @import("core/shell_completion.zig");
const session_search = @import("core/session_search.zig");

const AgentRuntime = agent_runtime.AgentRuntime;

/// Normalize a slash-command string by rewriting "show" / "view" /
/// "display" / "status" / "?" synonyms on subcommands into the
/// canonical "current" form that zcode's existing switch matches.
/// Matches COMMON_INFO_ARGS in claude-code-main/src/constants/xml.ts
/// so power users coming from Claude Code can type `/model show` or
/// `/model ?` and get the same behavior as `/model current` instead
/// of getting "unknown command".
///
/// Only rewrites a trailing single-word info arg after a known base
/// command. Any other shape passes through untouched so the rest of
/// the parser keeps control of its own argument syntax.
fn normalizeCommandSynonyms(buf: *[128]u8, command: []const u8) []const u8 {
    const info_bases = [_][]const u8{ "/model", "/agent", "/effort", "/format", "/preprocessor", "/memory", "/mode", "/session", "/lang" };
    const info_synonyms = [_][]const u8{ "show", "view", "display", "get", "describe", "print", "status", "about", "?" };

    for (info_bases) |base| {
        if (command.len <= base.len + 1) continue;
        if (!std.mem.startsWith(u8, command, base)) continue;
        if (command[base.len] != ' ') continue;
        const arg = std.mem.trim(u8, command[base.len + 1 ..], " \t");
        if (arg.len == 0 or arg.len > 16) continue;
        var matched = false;
        for (info_synonyms) |syn| {
            if (std.mem.eql(u8, arg, syn)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        // Rewrite to `<base> current` if it fits in buf.
        const rewritten_len = base.len + " current".len;
        if (rewritten_len >= buf.len) return command;
        @memcpy(buf[0..base.len], base);
        @memcpy(buf[base.len..rewritten_len], " current");
        return buf[0..rewritten_len];
    }
    return command;
}

/// True when `arg` looks like a request for help: `help`, `-h`,
/// `--help`. Ported from COMMON_HELP_ARGS in
/// claude-code-main/src/constants/xml.ts. Used by the
/// universal-help short-circuit in replCommandCallback so
/// `/model --help`, `/effort -h`, `/pr-comments help` all fall
/// through to /help instead of erroring.
fn isHelpArg(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "help")) return true;
    if (std.mem.eql(u8, arg, "-h")) return true;
    if (std.mem.eql(u8, arg, "--help")) return true;
    return false;
}

/// Extract the focusing directive from a `/compact <instructions>` command
/// (compaction-06, Task 4). Returns the trailing text trimmed of surrounding
/// whitespace; the bare `/compact` form (and `/compact ` with only trailing
/// whitespace) yields the empty string, which the compaction path treats as
/// "no instructions". The result borrows from `command` and is valid for its
/// lifetime. Factored out so the arg parse is unit-testable without a runtime.
fn parseCompactInstructions(command: []const u8) []const u8 {
    const prefix = "/compact ";
    if (!std.mem.startsWith(u8, command, prefix)) return "";
    return std.mem.trim(u8, command[prefix.len..], " \t\r\n");
}

/// P3 (PRD #534): apply a live permission-mode cycle to the runtime's state.
/// This is the runtime side of the Shift+Tab wire: the REPL cycles its local
/// permission mode and sends `__set_permission_mode <name>`; this updates the
/// override the tool gate reads AND runs the dangerous-rule strip/restore so
/// entering `plan` removes broad `Bash(*)` allow rules and leaving it restores
/// them. Factored as a free function (operating on the runtime's fields by
/// pointer) so the wire's observable effect is testable without building a full
/// AgentRuntime.
pub fn applyPermissionModeCycle(
    allocator: std.mem.Allocator,
    override_slot: *?permission_decision_mod.Mode,
    store: *permission_rules_mod.Store,
    stash_slot: *?[]permission_rules_mod.Rule,
    name: []const u8,
) !void {
    const new_mode = permission_decision_mod.modeFromString(name);
    const old_mode = override_slot.* orelse .default;
    override_slot.* = new_mode;
    try agent_runtime.applyModeTransitionToStore(allocator, store, stash_slot, old_mode, new_mode);
}

pub fn replCommandCallback(ctx: *anyopaque, allocator: std.mem.Allocator, command_raw: []const u8) !?[]u8 {
    const runtime: *AgentRuntime = @ptrCast(@alignCast(ctx));

    // CJK-IME normalisation: rewrite full-width ASCII digits
    // (U+FF10..U+FF19) and the ideographic space (U+3000) down to
    // plain ASCII before the rest of the dispatcher runs. Without
    // this a user typing `/model　１` from a Japanese IME would
    // see "unknown command" because the tokenizer sees a 3-byte
    // blob where it expected 0x20 + '1'. Ported from
    // claude-code-main/src/utils/stringUtils.ts
    // normalizeFullWidthDigits + normalizeFullWidthSpace.
    const normalized_raw = try parse_helpers.normalizeCjkInputAlloc(allocator, command_raw);
    defer allocator.free(normalized_raw);

    var synonym_buf: [128]u8 = undefined;
    const synonym_normalized = normalizeCommandSynonyms(&synonym_buf, normalized_raw);

    // Reference-spelling reconciliation (PRD #534 P1): rewrite the leading
    // command word from a reference-only spelling (e.g. /output-style,
    // /terminalSetup) to a form the dispatcher already matches, so Claude Code
    // users typing the reference name resolve correctly.
    var dispatch_buf: [256]u8 = undefined;
    const command = blk: {
        const sp = std.mem.indexOfScalar(u8, synonym_normalized, ' ');
        const head = if (sp) |i| synonym_normalized[0..i] else synonym_normalized;
        const mapped = command_canonical.toDispatch(head);
        if (std.mem.eql(u8, mapped, head)) break :blk synonym_normalized;
        const tail = if (sp) |i| synonym_normalized[i..] else "";
        const total = mapped.len + tail.len;
        if (total >= dispatch_buf.len) break :blk synonym_normalized;
        @memcpy(dispatch_buf[0..mapped.len], mapped);
        @memcpy(dispatch_buf[mapped.len..total], tail);
        break :blk dispatch_buf[0..total];
    };

    // Universal --help / -h / help subarg on any slash command: route
    // the user to /help so they can find the canonical form of what
    // they were trying to run. Matches the reference's
    // COMMON_HELP_ARGS recognition; zcode previously returned
    // "unknown command" for any form other than the exact "/help".
    if (command.len > 1 and command[0] == '/') {
        const space = std.mem.indexOfScalar(u8, command, ' ');
        if (space) |idx| {
            const arg = std.mem.trim(u8, command[idx + 1 ..], " \t");
            if (isHelpArg(arg)) {
                return @as(?[]u8, try allocator.dupe(u8, "Run /help to see the full slash-command reference. Use /model current (or /effort current, etc) to check a specific subsystem's state."));
            }
        }
    }

    // Exact-match removals (PRD #534 P9b): zcode-only commands not present in
    // Claude Code are treated as unrecognized so the surface matches the
    // reference. This short-circuits their now-unreachable handlers. See
    // core/removed_commands.zig for the reviewable/vetoable list.
    if (removed_commands.isRemoved(command)) return null;

    // Reference commands zcode recognizes but answers with a stub or local
    // alternative (niche/easter-egg/cloud-only). None of these names collide
    // with a real zcode command, so consulting the table here is safe. (P9)
    if (cc_stub_commands.lookup(command)) |stub_msg| {
        return @as(?[]u8, try allocator.dupe(u8, stub_msg));
    }

    if (std.mem.eql(u8, command, "__plan_approve_on")) {
        runtime.plan_approved = true;
        return null;
    }
    if (std.mem.eql(u8, command, "__plan_approve_off")) {
        runtime.plan_approved = false;
        return null;
    }
    if (std.mem.eql(u8, command, "__yolo_on")) {
        runtime.yolo_mode = true;
        runtime.auto_approve_high = true;
        return null;
    }
    if (std.mem.eql(u8, command, "__yolo_off")) {
        runtime.yolo_mode = false;
        runtime.auto_approve_high = runtime.original_auto_approve_high;
        return null;
    }
    if (std.mem.eql(u8, command, "__consume_requested_mode")) {
        const requested = runtime.requested_mode orelse return null;
        runtime.requested_mode = null;
        return @as(?[]u8, try allocator.dupe(u8, repl.modeLabel(requested)));
    }
    // P3 (PRD #534): push a live permission-mode cycle from the REPL into the
    // runtime so the reference modes actually drive tool decisions. The REPL
    // (overlay Shift+Tab / confirm_cycle_mode dispatch) cycles its own local
    // permission_mode, then calls "__set_permission_mode <name>" so the runtime
    // (1) updates permission_mode_override (read by the tool gate) and
    // (2) runs transitionPermissionMode(old, new) so entering plan strips
    // dangerous Bash allow rules and leaving plan restores them.
    if (std.mem.startsWith(u8, command, "__set_permission_mode ")) {
        const name = std.mem.trim(u8, command["__set_permission_mode ".len..], " \t");
        try applyPermissionModeCycle(
            runtime.allocator,
            &runtime.permission_mode_override,
            &runtime.permission_rules,
            &runtime.stripped_dangerous_stash,
            name,
        );
        return null;
    }
    if (std.mem.eql(u8, command, "__shell_cwd")) {
        return @as(?[]u8, try allocator.dupe(u8, runtime.shell_cwd));
    }

    // ui-render-04: return the most recent assistant turn's persisted
    // extended-thinking text (or null if the last turn had none). The
    // REPL uses this to render the collapsed `∴ Thinking` line / full
    // transcript block after a turn completes. Walks back from the end
    // to the first assistant turn so a trailing system/tool turn does
    // not mask the reasoning of the answer just produced.
    if (std.mem.eql(u8, command, "__last_thinking")) {
        const turns = runtime.history.view();
        var i = turns.len;
        while (i > 0) {
            i -= 1;
            const turn = turns[i];
            if (turn.role != .assistant) continue;
            const t = turn.thinking orelse return null;
            if (t.len == 0) return null;
            return @as(?[]u8, try allocator.dupe(u8, t));
        }
        return null;
    }

    if (std.mem.eql(u8, command, "/session")) {
        const metrics = runtime.statusMetrics();
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        try out.writer().print("session_id={s}\n", .{runtime.session_id});
        try out.writer().print("turns={d}\n", .{runtime.history.len()});
        try out.writer().print("total_input_tokens={d}\n", .{metrics.total_input_tokens});
        try out.writer().print("total_output_tokens={d}\n", .{metrics.total_output_tokens});
        try out.writer().print("provider={s}\n", .{runtime.active_provider});
        try out.writer().print("model={s}\n", .{runtime.active_model});

        // Diagnostic extensions surfaced by the audit: agent,
        // breaker state, and session-bytes-on-disk help operators
        // answer "is my session healthy? what's the provider
        // doing?" without leaving the REPL.
        if (runtime.activeAgentName()) |name| {
            try out.writer().print("active_agent={s}\n", .{name});
        }
        const cb_label = runtime.lastCircuitStateLabel();
        if (cb_label.len > 0) {
            try out.writer().print("circuit_breaker={s}\n", .{cb_label});
        }
        // Best-effort disk size. A stat failure (session not yet
        // flushed to disk, permission issue) is non-fatal; omit
        // the line rather than error out the whole /session dump.
        const session_path = runtime.store.sessionPath(runtime.session_id) catch null;
        if (session_path) |p| {
            defer runtime.allocator.free(p);
            if (std.Io.Dir.cwd().statFile(rt.io, p, .{})) |stat| {
                try out.writer().print("session_bytes={d}\n", .{stat.size});
            } else |_| {}
        }

        return @as(?[]u8, try out.toOwnedSlice());
    }

    if (std.mem.eql(u8, command, "/session list") or std.mem.eql(u8, command, "/resume list")) {
        const entries = try runtime.store.list();
        defer runtime.store.freeSessionEntries(entries);
        if (entries.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "no saved sessions"));
        }
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        try out.writer().print("sessions ({d}):\n", .{entries.len});
        const max_display = @min(entries.len, 20);
        for (entries[0..max_display]) |entry| {
            const current_marker: []const u8 = if (std.mem.eql(u8, entry.id, runtime.session_id)) " (current)" else "";
            // Title precedence (Phase 11 sessions-06): user label, else AI
            // title, else id. currentTitle always allocates; show it only
            // when it differs from the raw id so unnamed sessions stay terse.
            const title = runtime.store.currentTitle(entry.id) catch try allocator.dupe(u8, entry.id);
            defer allocator.free(title);
            // Phase 11 sessions-07: git branch tag (best-effort; absent for
            // sessions started outside a repo or before the feature landed).
            const branch_owned = runtime.store.readBranch(entry.id) catch null;
            defer if (branch_owned) |b| allocator.free(b);
            if (std.mem.eql(u8, title, entry.id)) {
                try out.writer().print("  {s}  updated={d}{s}\n", .{ entry.id, entry.updated_ts, current_marker });
            } else {
                try out.writer().print("  {s}  {s}  updated={d}{s}\n", .{ entry.id, title, entry.updated_ts, current_marker });
            }
            if (branch_owned) |b| {
                try out.writer().print("      branch: {s}\n", .{b});
            }
            // Phase 11 sessions-07: one-line first-prompt preview so the list
            // is scannable without resuming. Truncated to keep rows tidy.
            const fp_owned = runtime.store.readFirstPrompt(entry.id) catch null;
            defer if (fp_owned) |fp| allocator.free(fp);
            if (fp_owned) |fp| {
                const preview = if (fp.len > 72) fp[0..72] else fp;
                const ellipsis: []const u8 = if (fp.len > 72) "..." else "";
                try out.writer().print("      first: {s}{s}\n", .{ preview, ellipsis });
            }
        }
        if (entries.len > max_display) {
            try out.writer().print("  ... and {d} more\n", .{entries.len - max_display});
        }
        try out.writer().writeAll("\nUse /resume <session-id> to load a session");
        return @as(?[]u8, try out.toOwnedSlice());
    }

    if (std.mem.startsWith(u8, command, "/resume ") and !std.mem.eql(u8, command, "/resume list")) {
        const arg = std.mem.trim(u8, command["/resume ".len..], " \t");
        if (arg.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /resume <session-id>\nUse /session list to see available sessions"));
        }

        // Exact-UUID fast path: a literal id loads directly so a real
        // session id is never fuzzy-hijacked by a label that happens to
        // share characters. Only fall back to fuzzy resolution when the
        // exact load fails (invalid/not-found id). A non-null return from
        // resolveAndLoad means a disambiguation/not-found message the caller
        // returns verbatim instead of resuming.
        var early_reply: ?[]u8 = null;
        const loaded = runtime.store.load(arg) catch blk: {
            // Fuzzy fallback: resolve the term against the session list.
            const entries = try runtime.store.list();
            defer runtime.store.freeSessionEntries(entries);

            const candidates = try allocator.alloc(session_search.Candidate, entries.len);
            defer allocator.free(candidates);
            for (entries, 0..) |e, i| {
                candidates[i] = .{ .id = e.id, .label = e.label orelse "" };
            }

            const target = try session_search.resolveResumeTarget(allocator, candidates, arg);
            switch (target) {
                .exact, .single => |id| {
                    // Load the resolved session (exact-id or single fuzzy match).
                    break :blk runtime.store.load(id) catch |err| {
                        const error_hints = @import("core/error_hints.zig");
                        early_reply = try error_hints.formatUiError(allocator, "failed to load session", err);
                        break :blk undefined;
                    };
                },
                .multiple => |ids| {
                    defer allocator.free(ids);
                    var out = std_io.StringBuilder.init(allocator);
                    errdefer out.deinit();
                    try out.writer().print("multiple sessions match '{s}':\n", .{arg});
                    for (ids) |id| {
                        var matched_label: []const u8 = "";
                        for (entries) |e| {
                            if (std.mem.eql(u8, e.id, id)) {
                                matched_label = e.label orelse "";
                                break;
                            }
                        }
                        if (matched_label.len > 0) {
                            try out.writer().print("  {s}  {s}\n", .{ id, matched_label });
                        } else {
                            try out.writer().print("  {s}\n", .{id});
                        }
                    }
                    try out.writer().writeAll("Use /resume <session-id> to pick one");
                    early_reply = try out.toOwnedSlice();
                    break :blk undefined;
                },
                .none => {
                    var out = std_io.StringBuilder.init(allocator);
                    errdefer out.deinit();
                    try out.writer().print("no session matches '{s}'", .{arg});
                    const n = @min(entries.len, 3);
                    if (n > 0) {
                        try out.writer().writeAll("\nrecent sessions:\n");
                        for (entries[0..n]) |e| {
                            try out.writer().print("  {s}\n", .{e.id});
                        }
                        try out.writer().writeAll("Use /session list for the full list");
                    } else {
                        try out.writer().writeAll("\nNo saved sessions yet");
                    }
                    early_reply = try out.toOwnedSlice();
                    break :blk undefined;
                },
            }
        };
        if (early_reply) |reply| return @as(?[]u8, reply);
        const session_id = loaded.id;
        defer {
            var l = loaded;
            l.deinit(runtime.allocator);
        }

        // Build everything we need in scratch locals first, so a mid-loop
        // OOM leaves the runtime completely unchanged. The previous
        // version freed the live history and swapped the snapshot BEFORE
        // cloning the new history turns, so an OOM during the append
        // loop left a partial history, the new snapshot installed, and
        // the old session_id still in place -- a broken but live runtime.

        // 1. Clone the new snapshot.
        const new_snapshot = try agent_runtime.cloneSnapshot(runtime.allocator, &loaded.snapshot);
        var snapshot_committed = false;
        errdefer if (!snapshot_committed) agent_runtime.freeSnapshot(runtime.allocator, new_snapshot);

        // 2. Clone the new session id.
        const new_id = try runtime.allocator.dupe(u8, loaded.id);
        errdefer runtime.allocator.free(new_id);

        // 3. Build the success message now so its allocPrint failure can
        //    still unwind the allocations above.
        const reply = try std.fmt.allocPrint(allocator, "resumed session {s} ({d} turns)", .{ session_id, loaded.history.len });
        errdefer allocator.free(reply);

        // 4. Stage the restored history. replaceWith is fallible but
        //    atomic: on OOM the current history is left intact and the
        //    new_id / new_snapshot errdefers unwind cleanly. This is the
        //    last fallible step before the infallible commit below.
        try runtime.history.replaceWith(loaded.history);

        // ---- Commit phase: no more fallible operations from here on. ----
        // Swap the snapshot.
        agent_runtime.freeSnapshot(runtime.allocator, runtime.snapshot);
        runtime.snapshot = new_snapshot;
        snapshot_committed = true;

        // Swap the session id.
        runtime.allocator.free(runtime.session_id);
        runtime.session_id = new_id;

        // Clear session-scoped tool approvals (security: don't carry over)
        runtime.session_approved_tools.clearRetainingCapacity();

        // Reset prompt-section cache: /clear starts a fresh session,
        // so sections tied to session identity (instructions, tool
        // catalogue, environment) must recompute on the next turn.
        runtime.prompt_sections_registry.invalidateAll();

        return @as(?[]u8, reply);
    }

    if (std.mem.eql(u8, command, "/resume")) {
        return @as(?[]u8, try allocator.dupe(u8, "usage: /resume <session-id>\nUse /session list to see available sessions"));
    }

    if (std.mem.eql(u8, command, "/session checkpoints")) {
        const checkpoints = try session_bundles.listCheckpointsForStore(allocator, runtime.store, runtime.session_id);
        defer session_bundles.freeCheckpointEntries(allocator, checkpoints);

        if (checkpoints.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "no checkpoints for current session"));
        }

        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        for (checkpoints) |entry| {
            try out.writer().print("{s}\tlabel={s}\tcreated={d}\n", .{ entry.id, entry.label, entry.created_ts });
        }
        return try out.toOwnedSlice();
    }

    if (std.mem.startsWith(u8, command, "/session checkpoint")) {
        const raw_label = std.mem.trim(u8, command["/session checkpoint".len..], " \t");
        var saved = try session_bundles.saveCheckpoint(
            allocator,
            runtime.store,
            runtime.cwd,
            runtime.session_id,
            if (raw_label.len > 0) raw_label else null,
        );
        defer saved.deinit(allocator);
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "checkpoint saved\tid={s}\tlabel={s}",
            .{ saved.id, saved.label },
        ));
    }

    if (std.mem.startsWith(u8, command, "/session restore")) {
        const raw_checkpoint = std.mem.trim(u8, command["/session restore".len..], " \t");
        return @as(?[]u8, try runtime.restoreCheckpoint(if (raw_checkpoint.len > 0) raw_checkpoint else null));
    }

    if (std.mem.startsWith(u8, command, "/session fork")) {
        const raw_label = std.mem.trim(u8, command["/session fork".len..], " \t");
        return @as(?[]u8, try runtime.forkSession(if (raw_label.len > 0) raw_label else null));
    }

    if (std.mem.eql(u8, command, "/agents")) {
        return @as(?[]u8, try agents_mod.renderList(allocator, runtime.cwd, runtime.activeAgentName()));
    }

    if (std.mem.eql(u8, command, "/hooks")) {
        return @as(?[]u8, try hooks_mod.renderList(allocator, runtime.cwd));
    }

    if (std.mem.eql(u8, command, "/styles")) {
        return @as(?[]u8, try output_styles_mod.renderList(allocator, runtime.cwd, runtime.output_style));
    }

    if (std.mem.eql(u8, command, "/skills")) {
        return @as(?[]u8, try skills_mod.renderList(allocator, runtime.cwd));
    }

    if (std.mem.eql(u8, command, "/style") or std.mem.eql(u8, command, "/style current")) {
        return @as(?[]u8, try output_styles_mod.renderDetail(allocator, runtime.cwd, runtime.output_style));
    }

    if (std.mem.startsWith(u8, command, "/style ")) {
        const requested_style = std.mem.trim(u8, command["/style ".len..], " \t");
        if (requested_style.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /style <name>"));
        }
        return @as(?[]u8, try runtime.switchOutputStyle(requested_style));
    }

    if (std.mem.eql(u8, command, "/marketplace sources")) {
        return @as(?[]u8, try marketplace_mod.renderSources(allocator));
    }

    if (std.mem.startsWith(u8, command, "/marketplace add ")) {
        const rest = std.mem.trim(u8, command["/marketplace add ".len..], " \t");
        const split_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /marketplace add <name> <url> [sha256]"));
        };
        const name = std.mem.trim(u8, rest[0..split_idx], " \t");
        const tail = std.mem.trim(u8, rest[split_idx + 1 ..], " \t");
        if (name.len == 0 or tail.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /marketplace add <name> <url> [sha256]"));
        }
        if (std.mem.indexOfScalar(u8, tail, ' ')) |second_idx| {
            const url = std.mem.trim(u8, tail[0..second_idx], " \t");
            const sha = std.mem.trim(u8, tail[second_idx + 1 ..], " \t");
            return @as(?[]u8, try marketplace_mod.addSource(allocator, name, url, if (sha.len > 0) sha else null));
        }
        return @as(?[]u8, try marketplace_mod.addSource(allocator, name, tail, null));
    }

    if (std.mem.startsWith(u8, command, "/marketplace remove ")) {
        const name = std.mem.trim(u8, command["/marketplace remove ".len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /marketplace remove <name>"));
        return @as(?[]u8, try marketplace_mod.removeSource(allocator, name));
    }

    if (std.mem.eql(u8, command, "/marketplace refresh")) {
        return @as(?[]u8, try marketplace_mod.refreshSources(allocator, null));
    }

    if (std.mem.startsWith(u8, command, "/marketplace refresh ")) {
        const name = std.mem.trim(u8, command["/marketplace refresh ".len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /marketplace refresh [name]"));
        return @as(?[]u8, try marketplace_mod.refreshSources(allocator, name));
    }

    if (std.mem.eql(u8, command, "/plugins")) {
        return @as(?[]u8, try plugins_mod.renderList(allocator, runtime.cwd));
    }

    if (std.mem.eql(u8, command, "/plugins marketplace")) {
        return @as(?[]u8, try marketplace_mod.renderList(allocator, runtime.cwd, .plugin));
    }

    if (std.mem.startsWith(u8, command, "/plugins marketplace ")) {
        const requested_market = std.mem.trim(u8, command["/plugins marketplace ".len..], " \t");
        return @as(?[]u8, try marketplace_mod.renderDetail(allocator, runtime.cwd, .plugin, requested_market));
    }

    if (std.mem.eql(u8, command, "/commands")) {
        return @as(?[]u8, try commands_mod.renderList(allocator, runtime.cwd));
    }

    if (std.mem.eql(u8, command, "/commands marketplace")) {
        return @as(?[]u8, try marketplace_mod.renderList(allocator, runtime.cwd, .command));
    }

    if (std.mem.startsWith(u8, command, "/commands marketplace ")) {
        const requested_market = std.mem.trim(u8, command["/commands marketplace ".len..], " \t");
        return @as(?[]u8, try marketplace_mod.renderDetail(allocator, runtime.cwd, .command, requested_market));
    }

    if (std.mem.eql(u8, command, "/trust")) {
        const trust = try trust_mod.renderStatus(allocator, runtime.cwd);
        defer allocator.free(trust);
        const security = try security_mod.renderStatusSummary(allocator, runtime.cwd);
        defer allocator.free(security);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s}{s}", .{ trust, security }));
    }

    if (std.mem.eql(u8, command, "/trust hooks")) {
        return @as(?[]u8, try security_mod.renderHookTrust(allocator, runtime.cwd));
    }

    if (std.mem.startsWith(u8, command, "/trust hook allow ")) {
        const path = std.mem.trim(u8, command["/trust hook allow ".len..], " \t");
        if (path.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /trust hook allow <path>"));
        return @as(?[]u8, try security_mod.allowHook(allocator, runtime.cwd, path));
    }

    if (std.mem.startsWith(u8, command, "/trust hook revoke ")) {
        const path = std.mem.trim(u8, command["/trust hook revoke ".len..], " \t");
        if (path.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /trust hook revoke <path>"));
        return @as(?[]u8, try security_mod.revokeHook(allocator, runtime.cwd, path));
    }

    if (std.mem.eql(u8, command, "/trust marketplace")) {
        return @as(?[]u8, try security_mod.renderMarketplacePolicy(allocator));
    }

    if (std.mem.startsWith(u8, command, "/trust marketplace allow ")) {
        const prefix = std.mem.trim(u8, command["/trust marketplace allow ".len..], " \t");
        if (prefix.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /trust marketplace allow <prefix>"));
        return @as(?[]u8, try security_mod.allowMarketplacePrefix(allocator, prefix));
    }

    if (std.mem.startsWith(u8, command, "/trust marketplace block ")) {
        const prefix = std.mem.trim(u8, command["/trust marketplace block ".len..], " \t");
        if (prefix.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /trust marketplace block <prefix>"));
        return @as(?[]u8, try security_mod.blockMarketplacePrefix(allocator, prefix));
    }

    if (std.mem.startsWith(u8, command, "/trust marketplace unblock ")) {
        const prefix = std.mem.trim(u8, command["/trust marketplace unblock ".len..], " \t");
        if (prefix.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /trust marketplace unblock <prefix>"));
        return @as(?[]u8, try security_mod.unblockMarketplacePrefix(allocator, prefix));
    }

    if (std.mem.eql(u8, command, "/agent") or std.mem.eql(u8, command, "/agent current")) {
        if (runtime.activeAgentName()) |name| {
            return @as(?[]u8, try agents_mod.renderDetail(allocator, runtime.cwd, name));
        }
        return @as(?[]u8, try allocator.dupe(u8, "no active agent"));
    }

    if (std.mem.startsWith(u8, command, "/agent ")) {
        const requested = std.mem.trim(u8, command["/agent ".len..], " \t");
        return @as(?[]u8, try runtime.activateAgentByName(requested));
    }

    if (std.mem.eql(u8, command, "/skill")) {
        return @as(?[]u8, try allocator.dupe(u8, "usage: /skill <name> [args]"));
    }

    if (std.mem.startsWith(u8, command, "/skill ")) {
        const requested = std.mem.trim(u8, command["/skill ".len..], " \t");
        if (requested.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /skill <name> [args]"));
        }
        if (std.mem.indexOfScalar(u8, requested, ' ')) |space_idx| {
            const name = std.mem.trim(u8, requested[0..space_idx], " \t");
            const args = std.mem.trim(u8, requested[space_idx + 1 ..], " \t");
            const prompt = try skills_mod.renderRun(allocator, runtime.cwd, name, args, runtime.session_id);
            defer allocator.free(prompt);
            // Record the invocation for usage-frequency ranking (misc-utils-15).
            skill_usage_mod.recordSkill(allocator, name);
            return @as(?[]u8, try runtime.handlePromptWithModeAndReporter(prompt, null, .execution));
        }
        return @as(?[]u8, try skills_mod.renderDetail(allocator, runtime.cwd, requested));
    }

    if (std.mem.eql(u8, command, "/plugin") or std.mem.eql(u8, command, "/plugins")) {
        // Bare /plugin with no subcommand: list installed plugins.
        // Reference opens an interactive menu; zcode's non-interactive
        // equivalent is the list view.
        return @as(?[]u8, try plugins_mod.renderList(allocator, runtime.cwd));
    }

    if (std.mem.startsWith(u8, command, "/plugin ")) {
        if (std.mem.startsWith(u8, command, "/plugin install ")) {
            const requested_install = std.mem.trim(u8, command["/plugin install ".len..], " \t");
            if (requested_install.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin install <name>"));
            }
            return @as(?[]u8, try marketplace_mod.install(allocator, runtime.cwd, .plugin, requested_install));
        }
        if (std.mem.startsWith(u8, command, "/plugin uninstall ")) {
            const requested_uninstall = std.mem.trim(u8, command["/plugin uninstall ".len..], " \t");
            if (requested_uninstall.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin uninstall <name>"));
            }
            return @as(?[]u8, try marketplace_mod.uninstall(allocator, .plugin, requested_uninstall));
        }
        if (std.mem.startsWith(u8, command, "/plugin update ")) {
            const requested_update = std.mem.trim(u8, command["/plugin update ".len..], " \t");
            if (requested_update.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin update <name>"));
            }
            return @as(?[]u8, try marketplace_mod.update(allocator, runtime.cwd, .plugin, requested_update));
        }

        const requested = std.mem.trim(u8, command["/plugin ".len..], " \t");
        if (std.mem.eql(u8, requested, "install")) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin install <name>"));
        }
        if (std.mem.eql(u8, requested, "uninstall")) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin uninstall <name>"));
        }
        if (std.mem.eql(u8, requested, "update")) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /plugin update <name>"));
        }
        if (std.mem.startsWith(u8, requested, "marketplace")) {
            const detail = std.mem.trim(u8, requested["marketplace".len..], " \t");
            return @as(?[]u8, if (detail.len > 0)
                try marketplace_mod.renderDetail(allocator, runtime.cwd, .plugin, detail)
            else
                try marketplace_mod.renderList(allocator, runtime.cwd, .plugin));
        }
        return @as(?[]u8, try plugins_mod.renderDetail(allocator, runtime.cwd, requested));
    }

    if (std.mem.startsWith(u8, command, "/command ")) {
        const requested = std.mem.trim(u8, command["/command ".len..], " \t");
        if (requested.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /command <name> [args]"));
        }
        if (std.mem.eql(u8, requested, "install")) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /command install <name>"));
        }
        if (std.mem.startsWith(u8, requested, "install ")) {
            const requested_install = std.mem.trim(u8, requested["install ".len..], " \t");
            if (requested_install.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /command install <name>"));
            }
            return @as(?[]u8, try marketplace_mod.install(allocator, runtime.cwd, .command, requested_install));
        }
        if (std.mem.startsWith(u8, requested, "uninstall ")) {
            const requested_uninstall = std.mem.trim(u8, requested["uninstall ".len..], " \t");
            if (requested_uninstall.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /command uninstall <name>"));
            }
            return @as(?[]u8, try marketplace_mod.uninstall(allocator, .command, requested_uninstall));
        }
        if (std.mem.startsWith(u8, requested, "update ")) {
            const requested_update = std.mem.trim(u8, requested["update ".len..], " \t");
            if (requested_update.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /command update <name>"));
            }
            return @as(?[]u8, try marketplace_mod.update(allocator, runtime.cwd, .command, requested_update));
        }
        if (std.mem.startsWith(u8, requested, "marketplace")) {
            const detail = std.mem.trim(u8, requested["marketplace".len..], " \t");
            return @as(?[]u8, if (detail.len > 0)
                try marketplace_mod.renderDetail(allocator, runtime.cwd, .command, detail)
            else
                try marketplace_mod.renderList(allocator, runtime.cwd, .command));
        }
        if (std.mem.indexOfScalar(u8, requested, ' ')) |space_idx| {
            const name = std.mem.trim(u8, requested[0..space_idx], " \t");
            const args = std.mem.trim(u8, requested[space_idx + 1 ..], " \t");
            const prompt = try commands_mod.renderRun(allocator, runtime.cwd, name, args);
            defer allocator.free(prompt);
            // Record the invocation for usage-frequency ranking (misc-utils-15).
            skill_usage_mod.recordSkill(allocator, name);
            return @as(?[]u8, try runtime.handlePromptWithModeAndReporter(prompt, null, .execution));
        }
        return @as(?[]u8, try commands_mod.renderDetail(allocator, runtime.cwd, requested));
    }

    if (std.mem.eql(u8, command, "/init")) {
        // Drop a starter `ZCODE.md` in the current shell cwd with
        // the section skeleton zcode (and reference claude-code)
        // reads into the system prompt at startup. Refuses to
        // overwrite an existing file so the user's edits can't be
        // clobbered by an accidental re-run.
        //
        // The skeleton is intentionally sparse -- just section
        // headers and short hint lines. The user (or a subsequent
        // model turn) fills in the bodies based on the actual
        // project.
        return @as(?[]u8, try handleInitSkeleton(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/pwd")) {
        // Show the current shell cwd. That's the directory the next
        // Bash/Read/Write call will run in; may drift from the
        // startup cwd if the model ran `cd` earlier.
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "{s}",
            .{runtime.shell_cwd},
        ));
    }

    if (std.mem.startsWith(u8, command, "/cd")) {
        // Usage: `/cd <path>` or `/cd ~` or `/cd` (alias for `~`).
        // Changes the shell cwd for subsequent tool calls. Goes
        // through the same tilde expansion helper Read/Write use.
        const raw_arg = if (command.len > 3) std.mem.trim(u8, command[3..], " \t") else "";
        const target = if (raw_arg.len == 0) "~" else raw_arg;

        const helpers_mod = @import("tools/helpers.zig");
        const expanded = helpers_mod.expandHomeTilde(allocator, target) catch {
            return @as(?[]u8, try allocator.dupe(u8, "/cd: allocation failed"));
        };
        defer allocator.free(expanded);

        const abs = if (std.fs.path.isAbsolute(expanded))
            try allocator.dupe(u8, expanded)
        else
            try std.fs.path.join(allocator, &.{ runtime.shell_cwd, expanded });
        errdefer allocator.free(abs);

        // Validate that the target exists and is a directory before
        // we mutate shell_cwd -- a bad /cd should leave the previous
        // cwd intact.
        const stat = std.Io.Dir.cwd().statFile(rt.io, abs, .{}) catch |err| {
            allocator.free(abs);
            return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "/cd failed: cannot stat '{s}' ({s}). Current cwd unchanged: {s}",
                .{ target, @errorName(err), runtime.shell_cwd },
            ));
        };
        if (stat.kind != .directory) {
            allocator.free(abs);
            return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "/cd failed: '{s}' is not a directory. Current cwd unchanged: {s}",
                .{ target, runtime.shell_cwd },
            ));
        }

        const old_cwd = runtime.shell_cwd;
        runtime.shell_cwd = abs;
        allocator.free(old_cwd);

        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "cwd -> {s}",
            .{runtime.shell_cwd},
        ));
    }

    if (std.mem.eql(u8, command, "/version") or std.mem.eql(u8, command, "/v")) {
        // Minimal, focused version output. Ports the reference
        // `/version` slash command which the reference uses so the
        // user can share "which build am I on?" in bug reports
        // without having to read the dense /status dump.
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "zcode {s}",
            .{build_options.app_version},
        ));
    }

    if (std.mem.eql(u8, command, "/tips") or std.mem.eql(u8, command, "/tip")) {
        // Rotating usage tip (PRD #534 P7). Seeded by the clock so repeated
        // calls surface different tips.
        const tips = @import("core/tips.zig");
        const seed: u64 = @intCast(@as(i64, @max(0, clock.nowSeconds())));
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "Tip: {s}", .{tips.pick(seed)}));
    }

    if (std.mem.eql(u8, command, "/whoami")) {
        // One-line answer to "which provider/model am I talking to?".
        // The full answer lives in /status; this is the quick glance
        // users want when they're just double-checking that a /model
        // switch landed.
        const agent_label = runtime.activeAgentName() orelse "<none>";
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "provider={s} model={s} agent={s} version={s}",
            .{
                runtime.active_provider,
                runtime.active_model,
                agent_label,
                build_options.app_version,
            },
        ));
    }

    if (std.mem.eql(u8, command, "/config") or std.mem.startsWith(u8, command, "/config ")) {
        return handleConfigCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "/features")) {
        return @as(?[]u8, try feature_gates_mod.renderEffective(allocator, runtime.cfg));
    }

    if (std.mem.eql(u8, command, "/context")) {
        return handleContextCommand(allocator, runtime);
    }

    if (std.mem.eql(u8, command, "/fast") or std.mem.startsWith(u8, command, "/fast ")) {
        return handleFastCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "/color") or std.mem.startsWith(u8, command, "/color ")) {
        const arg = if (command.len > "/color".len)
            std.mem.trim(u8, command["/color".len..], " \t")
        else
            "";

        // Re-home the legacy ANSI on/off toggle under explicit /color on|off
        // so the old behavior is not lost (the reference /color is a palette
        // command, not an ANSI switch).
        if (std.mem.eql(u8, arg, "on") or std.mem.eql(u8, arg, "off")) {
            const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
            mutable_cfg.ui_color_enabled = std.mem.eql(u8, arg, "on");
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "color: {s}", .{if (mutable_cfg.ui_color_enabled) "on" else "off"}));
        }

        return @as(?[]u8, try handleColorPalette(allocator, runtime.store, runtime.session_id, arg));
    }

    if (std.mem.eql(u8, command, "/status")) {
        const metrics = runtime.statusMetrics();
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        const w = out.writer();

        try w.print("provider={s}\n", .{runtime.active_provider});
        try w.print("model={s}\n", .{runtime.active_model});
        try w.print("active_agent={s}\n", .{runtime.activeAgentName() orelse "<none>"});
        try w.print("configured_default_provider={s}\n", .{runtime.cfg.default_provider});
        try w.print("configured_default_model={s}\n", .{runtime.cfg.default_model});
        try w.print("available_models={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.available_models, "<none>")});
        try w.print("version={s}\n", .{build_options.app_version});
        try w.print("profile={s}\n", .{runtime.cfg.profile});
        try w.print("approval_mode={s}\n", .{runtime.cfg.approval_mode});
        try w.print("sandbox={s}\n", .{runtime.cfg.sandbox});
        try w.print("strict={}\n", .{runtime.strict});
        try w.print("yolo_mode={}\n", .{runtime.yolo_mode});
        try w.print("interactive_streaming={}\n", .{runtime.cfg.interactive_streaming});
        try w.print("intent_reprompt_enabled={}\n", .{runtime.cfg.intent_reprompt_enabled});
        try w.print("provider_timeout_ms={d}\n", .{runtime.cfg.provider_timeout_ms});
        try w.print("provider_retry_count={d}\n", .{runtime.cfg.provider_retry_count});
        try w.print("provider_api_key_configured={}\n", .{runtime.cfg.provider_api_key.len > 0});
        try w.print("provider_base_url={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.provider_base_url, "<env/default>")});
        try w.print("local_base_url={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.local_base_url, "<env/default>")});
        try w.print("fallback_provider={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.fallback_provider, "<none>")});
        try w.print("fallback_model={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.fallback_model, "<none>")});
        try w.print("fallback_provider_api_key_configured={}\n", .{runtime.cfg.fallback_provider_api_key.len > 0});
        try w.print("fallback_provider_base_url={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.fallback_provider_base_url, "<env/default>")});
        try w.print("ui_fullscreen={}\n", .{runtime.cfg.ui_fullscreen});
        try w.print("ui_alt_screen={}\n", .{runtime.cfg.ui_alt_screen});
        try w.print("ui_spinner={}\n", .{runtime.cfg.ui_spinner});
        try w.print("ui_thinking_summary={}\n", .{runtime.cfg.ui_thinking_summary});
        try w.print("ui_brief_mode={}\n", .{runtime.cfg.ui_brief_mode});
        try w.print("ui_vim_mode={}\n", .{runtime.cfg.ui_vim_mode});
        try w.print("ui_prompt_label={s}\n", .{runtime.cfg.ui_prompt_label});
        try w.print("ui_transcript_max_lines={d}\n", .{runtime.cfg.ui_transcript_max_lines});
        try w.print("ui_show_scroll_hint={}\n", .{runtime.cfg.ui_show_scroll_hint});
        try w.print("ui_bottom_margin_rows={d}\n", .{runtime.cfg.ui_bottom_margin_rows});
        try w.print("ui_line_spacing={d}\n", .{runtime.cfg.ui_line_spacing});
        try w.print("ui_color_enabled={}\n", .{runtime.cfg.ui_color_enabled});
        try w.print("ui_theme={s}\n", .{runtime.cfg.ui_theme});
        try w.print("ui_highlight_links={}\n", .{runtime.cfg.ui_highlight_links});
        try w.print("ui_highlight_paths={}\n", .{runtime.cfg.ui_highlight_paths});
        try w.print("ui_color_lists={}\n", .{runtime.cfg.ui_color_lists});
        try w.print("ui_highlight_code_blocks={}\n", .{runtime.cfg.ui_highlight_code_blocks});
        try w.print("ui_status_show_workspace={}\n", .{runtime.cfg.ui_status_show_workspace});
        try w.print("ui_status_show_model={}\n", .{runtime.cfg.ui_status_show_model});
        try w.print("ui_status_show_safety={}\n", .{runtime.cfg.ui_status_show_safety});
        try w.print("ui_status_show_tokens={}\n", .{runtime.cfg.ui_status_show_tokens});
        try w.print("ui_status_show_hint={}\n", .{runtime.cfg.ui_status_show_hint});
        try w.print("max_history_turns={d}\n", .{runtime.cfg.max_history_turns});
        try w.print("max_tool_rounds={d}\n", .{runtime.cfg.max_tool_rounds});
        try w.print("mcp_tool_bridge_enabled={}\n", .{runtime.cfg.mcp_tool_bridge_enabled});
        try w.print("feature_kill_switches={s}\n", .{agent_runtime.displayValueOr(runtime.cfg.feature_kill_switches, "<none>")});
        try w.print("session_encryption_enabled={}\n", .{runtime.cfg.session_encryption_enabled});
        try w.print("prompt_cache_hints_enabled={}\n", .{runtime.cfg.prompt_cache_hints_enabled});
        try w.print("append_system_prompt_set={}\n", .{runtime.cfg.append_system_prompt.len > 0});
        const pre_settings = runtime.resolvedPreprocessorSettings();
        try w.print("preprocessor_enabled={}\n", .{runtime.preprocessor_enabled});
        try w.print("preprocessor_provider={s}\n", .{agent_runtime.displayValueOr(runtime.preprocessor_provider, "<none>")});
        try w.print("preprocessor_model={s}\n", .{agent_runtime.displayValueOr(runtime.preprocessor_model, "<none>")});
        try w.print("preprocessor_base_url={s}\n", .{agent_runtime.displayValueOr(runtime.preprocessor_base_url, "<auto/env>")});
        try w.print("preprocessor_api_key_configured={}\n", .{runtime.preprocessor_api_key.len > 0});
        try w.print("preprocessor_max_output_tokens={d}\n", .{runtime.preprocessor_max_output_tokens});
        try w.print("effective_preprocessor_provider={s}\n", .{agent_runtime.displayValueOr(pre_settings.provider, "<none>")});
        try w.print("effective_preprocessor_model={s}\n", .{agent_runtime.displayValueOr(pre_settings.model, "<none>")});
        try w.print("effective_preprocessor_base_url={s}\n", .{agent_runtime.displayValueOr(pre_settings.base_url orelse "", "<env/default>")});
        try w.print("effective_preprocessor_api_key_configured={}\n", .{pre_settings.api_key != null});
        try w.print("last_prompt_tokens={d}\n", .{metrics.last_prompt_tokens});
        try w.print("last_input_tokens={d}\n", .{metrics.last_input_tokens});
        try w.print("last_output_tokens={d}\n", .{metrics.last_output_tokens});
        try w.print("total_input_tokens={d}\n", .{metrics.total_input_tokens});
        try w.print("total_output_tokens={d}\n", .{metrics.total_output_tokens});
        try w.print("last_cache_hints={d}\n", .{metrics.last_cache_hints});
        try w.print("last_budget_input={d}\n", .{metrics.last_budget_input});

        return @as(?[]u8, try out.toOwnedSlice());
    }

    if (std.mem.eql(u8, command, "/compact") or std.mem.startsWith(u8, command, "/compact ")) {
        // Phase 8 (compaction-18): forceCompaction now centralizes the
        // post-compact cleanup (prompt-section cache invalidation) via
        // compactionCleanup, so both the manual and auto paths reset the same
        // caches. The inline invalidateAll() that used to live here is gone --
        // compaction rewrites history and typically follows a context-pressure
        // event, and the centralized cleanup discards any stale rendered prefix.
        //
        // Phase 8 (compaction-06, Task 4): `/compact <instructions>` passes the
        // trailing text as a focusing directive into the summarizer prompt
        // (mirrors /brief and /density which use startsWith at the branches
        // below). The no-arg form yields an empty instruction string, which
        // behaves exactly as before. We trim leading/trailing whitespace so a
        // bare "/compact " (trailing space, no text) is identical to "/compact".
        const instructions = parseCompactInstructions(command);
        try runtime.forceCompactionWithInstructions("manual", instructions);
        // ui-render-05: surface the styled compaction boundary instead of the
        // bare "compaction complete" note. The text is emitted color-agnostic
        // (no SGR) here -- the REPL's transcript sanitizer strips color in
        // fullscreen, and the non-fullscreen markdown render path does not
        // expect raw escape bytes. The dim styling lives in the pure
        // `renderCompactBoundary` render unit for callers that own a color
        // decision; the load-bearing visible change is the ✻ glyph + the new
        // body + the ctrl+o-for-history hint.
        var boundary_buf: [128]u8 = undefined;
        var bw = std.Io.Writer.fixed(&boundary_buf);
        compaction_mod.renderCompactBoundary(&bw, false) catch
            return @as(?[]u8, try allocator.dupe(u8, "compaction complete"));
        return @as(?[]u8, try allocator.dupe(u8, bw.buffered()));
    }

    if (std.mem.eql(u8, command, "/brief") or std.mem.startsWith(u8, command, "/brief ")) {
        return handleBriefCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "/density") or std.mem.startsWith(u8, command, "/density ")) {
        return handleDensityCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "/vim") or std.mem.startsWith(u8, command, "/vim ")) {
        return handleVimCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "__style_current_name")) {
        return @as(?[]u8, try allocator.dupe(u8, runtime.output_style));
    }

    if (std.mem.eql(u8, command, "__todos_overlay_data")) {
        return @as(?[]u8, try todos_mod.read(allocator, &runtime.snapshot));
    }

    if (std.mem.eql(u8, command, "__tasks_overlay_data")) {
        return @as(?[]u8, try renderTasksOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__sessions_overlay_data")) {
        return @as(?[]u8, try renderSessionsOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__teams_overlay_data")) {
        return @as(?[]u8, try renderTeamsOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__bridge_overlay_data")) {
        return @as(?[]u8, try renderBridgeOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__tasks_footer_state")) {
        return @as(?[]u8, try renderTasksFooterState(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__teams_footer_state")) {
        return @as(?[]u8, try renderTeamsFooterState(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__bridge_footer_state")) {
        return @as(?[]u8, try renderBridgeFooterState(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__agent_footer_state")) {
        return @as(?[]u8, try renderActiveAgentFooterState(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__tmux_footer_state")) {
        return @as(?[]u8, try renderTmuxFooterState(allocator));
    }

    if (std.mem.eql(u8, command, "__worktree_footer_state")) {
        return @as(?[]u8, try renderWorktreeFooterState(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_agents")) {
        return @as(?[]u8, try renderPromptSuggestionAgents(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_teams")) {
        return @as(?[]u8, try renderPromptSuggestionTeams(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_commands")) {
        return @as(?[]u8, try renderPromptSuggestionCommands(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_skills")) {
        return @as(?[]u8, try renderPromptSuggestionSkills(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_mcp")) {
        return @as(?[]u8, try renderPromptSuggestionMcp(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__prompt_suggestion_shell_bins")) {
        return @as(?[]u8, try renderPromptSuggestionShellBins(allocator));
    }

    // Context-aware shell completion (bash-shell-06). The current line is
    // passed after a tab: "__prompt_suggestion_shell_completions\t<input>".
    // Falls back to the PATH-scan command list when live completion is
    // unavailable (non-bash/zsh shell, timeout, or empty result).
    if (std.mem.startsWith(u8, command, "__prompt_suggestion_shell_completions")) {
        const tab = std.mem.indexOfScalar(u8, command, '\t');
        const line = if (tab) |i| command[i + 1 ..] else "";
        return @as(?[]u8, try renderPromptSuggestionShellCompletions(allocator, line));
    }

    if (std.mem.eql(u8, command, "__prompt_reference_suggestions")) {
        return @as(?[]u8, try renderPromptReferenceSuggestions(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__tasks_running_count")) {
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "{d}", .{try countManagedBackgroundTasks(allocator, runtime)}));
    }

    if (std.mem.startsWith(u8, command, "__task_stop ")) {
        const id = std.mem.trim(u8, command["__task_stop ".len..], " \t");
        if (id.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "task stop failed: missing task id"));
        }
        return @as(?[]u8, try task_mod.taskStop(allocator, runtime.cwd, id));
    }

    if (std.mem.eql(u8, command, "__tasks_stop_all")) {
        return @as(?[]u8, try stopAllManagedBackgroundTasks(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/todos")) {
        return @as(?[]u8, try todos_mod.read(allocator, &runtime.snapshot));
    }

    if (std.mem.eql(u8, command, "/tasks") or
        std.mem.eql(u8, command, "/tasks list") or
        std.mem.eql(u8, command, "/bashes"))
    {
        return @as(?[]u8, try task_mod.taskList(allocator, runtime.cwd, null));
    }

    if (std.mem.startsWith(u8, command, "/tasks stop ")) {
        const id = std.mem.trim(u8, command["/tasks stop ".len..], " \t");
        if (id.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /tasks stop <task-id>"));
        }
        return @as(?[]u8, try task_mod.taskStop(allocator, runtime.cwd, id));
    }

    if (std.mem.eql(u8, command, "/tasks stop-all")) {
        return @as(?[]u8, try stopAllManagedBackgroundTasks(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/teams")) {
        return @as(?[]u8, try renderTeamsOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/bridge")) {
        return @as(?[]u8, try renderBridgeOverlayData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/models")) {
        return @as(?[]u8, try renderReplModels(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__model_picker_data")) {
        return @as(?[]u8, try renderReplModelPickerData(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "__rewind_picker_data")) {
        return @as(?[]u8, try renderRewindPickerData(allocator, runtime));
    }

    if (std.mem.startsWith(u8, command, "__rewind_apply_code ")) {
        const arg = std.mem.trim(u8, command["__rewind_apply_code ".len..], " \t");
        const history_index = std.fmt.parseInt(usize, arg, 10) catch {
            return @as(?[]u8, try allocator.dupe(u8, "rewind failed: invalid prompt selection"));
        };
        return @as(?[]u8, try handleRewindToHistoryIndexWithCode(allocator, runtime, history_index));
    }

    if (std.mem.startsWith(u8, command, "__rewind_apply ")) {
        const arg = std.mem.trim(u8, command["__rewind_apply ".len..], " \t");
        const history_index = std.fmt.parseInt(usize, arg, 10) catch {
            return @as(?[]u8, try allocator.dupe(u8, "rewind failed: invalid prompt selection"));
        };
        return @as(?[]u8, try handleRewindToHistoryIndex(allocator, runtime, history_index));
    }

    if (std.mem.eql(u8, command, "/model") or std.mem.eql(u8, command, "/model list")) {
        return @as(?[]u8, try renderReplModels(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/model current")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "active provider/model: {s}/{s}",
            .{ runtime.active_provider, runtime.active_model },
        ));
    }

    if (std.mem.startsWith(u8, command, "/model ")) {
        const requested = std.mem.trim(u8, command["/model ".len..], " \t");
        if (requested.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /model <id|provider/id> | /model list | /model current"));
        }
        if (std.mem.eql(u8, requested, "list")) {
            return @as(?[]u8, try renderReplModels(allocator, runtime));
        }
        if (std.mem.eql(u8, requested, "current")) {
            return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "active provider/model: {s}/{s}",
                .{ runtime.active_provider, runtime.active_model },
            ));
        }
        return @as(?[]u8, try switchReplModel(allocator, runtime, requested));
    }

    // /env registry lists every ZCODE_* / provider / XDG env var zcode
    // reads, with values (secrets redacted). Matches `zcode --list-env`
    // on the CLI. Distinct from the existing `/env` / `/env list`
    // subcommand set which manages subprocess session env vars.
    if (std.mem.eql(u8, command, "/env registry")) {
        const env_registry = @import("core/env_registry.zig");
        return @as(?[]u8, try env_registry.renderTable(allocator));
    }

    if (std.mem.eql(u8, command, "/effort") or std.mem.eql(u8, command, "/effort current")) {
        return @as(?[]u8, try renderEffortStatus(allocator, runtime));
    }
    if (std.mem.startsWith(u8, command, "/effort ")) {
        const arg = std.mem.trim(u8, command["/effort ".len..], " \t");
        return @as(?[]u8, try handleEffortSet(allocator, runtime, arg));
    }

    // /format json <json-schema-object>  -- sets response_schema for
    // the next turn on OpenAI-compatible providers. /format clear or
    // /format off removes any pending schema.
    if (std.mem.eql(u8, command, "/format") or std.mem.eql(u8, command, "/format current")) {
        return @as(?[]u8, try renderFormatStatus(allocator, runtime));
    }
    if (std.mem.eql(u8, command, "/format clear") or std.mem.eql(u8, command, "/format off") or std.mem.eql(u8, command, "/format none")) {
        if (runtime.pending_response_schema) |schema| {
            runtime.allocator.free(schema);
            runtime.pending_response_schema = null;
        }
        return @as(?[]u8, try allocator.dupe(u8, "response format cleared"));
    }
    if (std.mem.startsWith(u8, command, "/format json ")) {
        const schema = std.mem.trim(u8, command["/format json ".len..], " \t");
        if (schema.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /format json <json-schema>"));
        }
        // Validate: must parse as a JSON object. Embedding a
        // malformed schema into the request body breaks the provider
        // call with a confusing error; rejecting it here keeps the
        // feedback local. We parse and discard the result.
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, schema, .{}) catch {
            return @as(?[]u8, try allocator.dupe(u8, "/format json: schema is not valid JSON"));
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            return @as(?[]u8, try allocator.dupe(u8, "/format json: schema must be a JSON object (e.g. {\"type\":\"object\", ...})"));
        }
        if (runtime.pending_response_schema) |prev| runtime.allocator.free(prev);
        runtime.pending_response_schema = try runtime.allocator.dupe(u8, schema);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "response format set ({d} bytes of schema). Next turn will enforce.", .{schema.len}));
    }
    if (std.mem.startsWith(u8, command, "/format ")) {
        return @as(?[]u8, try allocator.dupe(u8, "usage: /format [current|clear|json <schema>]"));
    }

    if (std.mem.eql(u8, command, "/preprocessor") or std.mem.eql(u8, command, "/preprocessor current")) {
        return @as(?[]u8, try renderReplPreprocessor(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/preprocessor list")) {
        return @as(?[]u8, try renderReplPreprocessorModels(allocator, runtime, null));
    }

    if (std.mem.startsWith(u8, command, "/preprocessor ")) {
        const requested = std.mem.trim(u8, command["/preprocessor ".len..], " \t");
        if (requested.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /preprocessor [current|on|off|list [provider]|<id|provider/id>]"));
        }
        if (std.mem.eql(u8, requested, "current")) {
            return @as(?[]u8, try renderReplPreprocessor(allocator, runtime));
        }
        if (std.mem.eql(u8, requested, "on")) {
            return @as(?[]u8, try setReplPreprocessorEnabled(allocator, runtime, true));
        }
        if (std.mem.eql(u8, requested, "off")) {
            return @as(?[]u8, try setReplPreprocessorEnabled(allocator, runtime, false));
        }
        if (std.mem.eql(u8, requested, "list")) {
            return @as(?[]u8, try renderReplPreprocessorModels(allocator, runtime, null));
        }
        if (std.mem.startsWith(u8, requested, "list ")) {
            const provider_name = std.mem.trim(u8, requested["list ".len..], " \t");
            if (provider_name.len == 0) {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /preprocessor list [provider]"));
            }
            return @as(?[]u8, try renderReplPreprocessorModels(allocator, runtime, provider_name));
        }
        return @as(?[]u8, try switchReplPreprocessor(allocator, runtime, requested));
    }

    if (std.mem.eql(u8, command, "/mcp")) {
        return @as(?[]u8, try renderReplMcpServers(allocator, runtime));
    }

    if (std.mem.startsWith(u8, command, "/mcp tools")) {
        const server = std.mem.trim(u8, command["/mcp tools".len..], " \t");
        if (server.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp tools <server>"));
        }
        return @as(?[]u8, try renderReplMcpTools(allocator, runtime, server));
    }

    if (std.mem.startsWith(u8, command, "/mcp resources")) {
        const server = std.mem.trim(u8, command["/mcp resources".len..], " \t");
        if (server.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp resources <server>"));
        }
        return @as(?[]u8, try renderReplMcpResources(allocator, runtime, server));
    }

    if (std.mem.startsWith(u8, command, "/mcp templates")) {
        const server = std.mem.trim(u8, command["/mcp templates".len..], " \t");
        if (server.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp templates <server>"));
        }
        return @as(?[]u8, try renderReplMcpTemplates(allocator, runtime, server));
    }

    if (std.mem.startsWith(u8, command, "/mcp read")) {
        const spec = std.mem.trim(u8, command["/mcp read".len..], " \t");
        const parsed = splitHeadTail(spec);
        if (parsed.head.len == 0 or parsed.tail.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp read <server> <uri>"));
        }
        return @as(?[]u8, try renderReplMcpRead(allocator, runtime, parsed.head, parsed.tail));
    }

    if (std.mem.startsWith(u8, command, "/mcp prompts")) {
        const server = std.mem.trim(u8, command["/mcp prompts".len..], " \t");
        if (server.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp prompts <server>"));
        }
        return @as(?[]u8, try renderReplMcpPrompts(allocator, runtime, server));
    }

    if (std.mem.startsWith(u8, command, "/mcp prompt")) {
        const spec = std.mem.trim(u8, command["/mcp prompt".len..], " \t");
        const server_and_rest = splitHeadTail(spec);
        const prompt_spec = splitHeadTail(server_and_rest.tail);
        if (server_and_rest.head.len == 0 or prompt_spec.head.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp prompt <server> <name> [json-args]"));
        }
        return @as(?[]u8, try renderReplMcpPrompt(
            allocator,
            runtime,
            server_and_rest.head,
            prompt_spec.head,
            if (prompt_spec.tail.len > 0) prompt_spec.tail else null,
        ));
    }

    if (std.mem.startsWith(u8, command, "/mcp complete")) {
        const spec = std.mem.trim(u8, command["/mcp complete".len..], " \t");
        const server_and_rest = splitHeadTail(spec);
        const ref_and_rest = splitHeadTail(server_and_rest.tail);
        const arg_and_value = splitHeadTail(ref_and_rest.tail);
        if (server_and_rest.head.len == 0 or ref_and_rest.head.len == 0 or arg_and_value.head.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp complete <server> <ref-json> <argument> [value]"));
        }
        return @as(?[]u8, try renderReplMcpComplete(
            allocator,
            runtime,
            server_and_rest.head,
            ref_and_rest.head,
            arg_and_value.head,
            if (arg_and_value.tail.len > 0) arg_and_value.tail else null,
        ));
    }

    if (std.mem.startsWith(u8, command, "/mcp subscribe")) {
        const spec = std.mem.trim(u8, command["/mcp subscribe".len..], " \t");
        const parsed = splitHeadTail(spec);
        if (parsed.head.len == 0 or parsed.tail.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp subscribe <server> <uri>"));
        }
        try runtime.mcp.subscribeResource(parsed.head, parsed.tail);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "subscribed to MCP resource {s}", .{parsed.tail}));
    }

    if (std.mem.startsWith(u8, command, "/mcp unsubscribe")) {
        const spec = std.mem.trim(u8, command["/mcp unsubscribe".len..], " \t");
        const parsed = splitHeadTail(spec);
        if (parsed.head.len == 0 or parsed.tail.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp unsubscribe <server> <uri>"));
        }
        try runtime.mcp.unsubscribeResource(parsed.head, parsed.tail);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "unsubscribed from MCP resource {s}", .{parsed.tail}));
    }

    if (std.mem.startsWith(u8, command, "/mcp log-level")) {
        const spec = std.mem.trim(u8, command["/mcp log-level".len..], " \t");
        const parsed = splitHeadTail(spec);
        if (parsed.head.len == 0 or parsed.tail.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /mcp log-level <server> <level>"));
        }
        try runtime.mcp.setLoggingLevel(parsed.head, parsed.tail);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "set MCP log level for {s} to {s}", .{ parsed.head, parsed.tail }));
    }

    if (std.mem.startsWith(u8, command, "/mcp notifications")) {
        const server = std.mem.trim(u8, command["/mcp notifications".len..], " \t");
        return @as(?[]u8, try renderReplMcpNotifications(allocator, runtime, if (server.len > 0) server else null));
    }

    if (std.mem.eql(u8, command, "/policy")) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try runtime.policy.print(out.writer());
        return @as(?[]u8, try out.toOwnedSlice());
    }

    if (std.mem.eql(u8, command, "/cost")) {
        const metrics = runtime.statusMetrics();
        return @as(?[]u8, try cost_mod.renderCostReport(
            allocator,
            runtime.active_provider,
            runtime.active_model,
            metrics.last_input_tokens,
            metrics.last_output_tokens,
            metrics.total_input_tokens,
            metrics.total_output_tokens,
            &runtime.model_usage,
        ));
    }

    if (std.mem.eql(u8, command, "/usage")) {
        return @as(?[]u8, try renderUsageSummary(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/stickers")) {
        return @as(?[]u8, try openStickersPage(allocator));
    }

    if (std.mem.eql(u8, command, "/upgrade") or std.mem.eql(u8, command, "/update")) {
        return @as(?[]u8, try handleUpgrade(allocator, runtime.cfg));
    }

    if (std.mem.eql(u8, command, "/sandbox") or std.mem.eql(u8, command, "/sandbox-toggle")) {
        return @as(?[]u8, try renderSandboxStatus(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/keybindings")) {
        return @as(?[]u8, try openKeybindingsInEditor(allocator));
    }

    if (std.mem.eql(u8, command, "/reload-plugins") or std.mem.eql(u8, command, "/reload_plugins")) {
        return @as(?[]u8, try rescanPluginsAndReport(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/pr-comments") or std.mem.eql(u8, command, "/pr_comments")) {
        return @as(?[]u8, try fetchPrComments(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/pr-status") or std.mem.eql(u8, command, "/pr_status")) {
        return @as(?[]u8, try fetchPrStatus(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/rewind") or std.mem.eql(u8, command, "/checkpoint")) {
        return @as(?[]u8, try handleRewind(allocator, runtime, 1));
    }
    if (std.mem.startsWith(u8, command, "/rewind ")) {
        const arg = std.mem.trim(u8, command["/rewind ".len..], " \t");
        const n = std.fmt.parseInt(usize, arg, 10) catch {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /rewind [N]  (drop the last N assistant turns from the in-memory conversation)"));
        };
        if (n == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "/rewind: count must be > 0"));
        }
        return @as(?[]u8, try handleRewind(allocator, runtime, n));
    }

    if (std.mem.eql(u8, command, "/memory") or std.mem.eql(u8, command, "/memory list")) {
        return @as(?[]u8, try memory_mod.listWithWorkspace(allocator, runtime.cwd));
    }
    if (std.mem.startsWith(u8, command, "/memory save ")) {
        const args_text = std.mem.trim(u8, command["/memory save ".len..], " \t");
        // Parse: /memory save <category> <name> <content>
        const first_space = std.mem.indexOfScalar(u8, args_text, ' ') orelse return @as(?[]u8, try allocator.dupe(u8, "usage: /memory save <category> <name> <content>\ncategories: rule (always enforced), feedback (always enforced), user, project, reference"));
        const category_str = args_text[0..first_space];
        const rest = std.mem.trim(u8, args_text[first_space + 1 ..], " \t");
        const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return @as(?[]u8, try allocator.dupe(u8, "usage: /memory save <category> <name> <content>"));
        const name_str = rest[0..second_space];
        const content_str = std.mem.trim(u8, rest[second_space + 1 ..], " \t");
        if (content_str.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /memory save <category> <name> <content>"));
        return @as(?[]u8, try memory_mod.save(allocator, name_str, category_str, content_str));
    }
    if (std.mem.startsWith(u8, command, "/memory delete ")) {
        const name_str = std.mem.trim(u8, command["/memory delete ".len..], " \t");
        if (name_str.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /memory delete <name>"));
        return @as(?[]u8, try memory_mod.delete(allocator, name_str));
    }

    if (std.mem.eql(u8, command, "/review")) {
        var plugin_result = try plugins_mod.run(allocator, .{
            .event = .review_start,
            .cwd = runtime.cwd,
        });
        defer plugin_result.deinit(allocator);
        if (plugin_result.blocked) {
            return @as(?[]u8, try allocator.dupe(u8, if (plugin_result.output.len > 0) plugin_result.output else "review blocked by plugin"));
        }
        const prompt = try review_flow.buildPrompt(allocator, null);
        defer allocator.free(prompt);
        const review_output = try runtime.handlePromptWithModeAndReporter(prompt, null, .review);
        if (plugin_result.output.len == 0) return @as(?[]u8, review_output);
        defer allocator.free(review_output);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "[plugin] {s}\n\n{s}", .{ plugin_result.output, review_output }));
    }

    if (std.mem.startsWith(u8, command, "/review ")) {
        var plugin_result = try plugins_mod.run(allocator, .{
            .event = .review_start,
            .cwd = runtime.cwd,
        });
        defer plugin_result.deinit(allocator);
        if (plugin_result.blocked) {
            return @as(?[]u8, try allocator.dupe(u8, if (plugin_result.output.len > 0) plugin_result.output else "review blocked by plugin"));
        }
        const requested = std.mem.trim(u8, command["/review ".len..], " \t");
        const prompt = review_flow.buildPrompt(allocator, requested) catch |err| switch (err) {
            error.InvalidReviewTarget => return @as(?[]u8, try allocator.dupe(u8, review_flow.usage)),
            else => return err,
        };
        defer allocator.free(prompt);
        const review_output = try runtime.handlePromptWithModeAndReporter(prompt, null, .review);
        if (plugin_result.output.len == 0) return @as(?[]u8, review_output);
        defer allocator.free(review_output);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "[plugin] {s}\n\n{s}", .{ plugin_result.output, review_output }));
    }

    if (std.mem.eql(u8, command, "/security-review") or std.mem.eql(u8, command, "/security_review")) {
        const prompt = try review_flow.buildSecurityReviewPrompt(allocator);
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePromptWithModeAndReporter(prompt, null, .review));
    }

    // ── Feedback ──

    if (std.mem.eql(u8, command, "/feedback")) {
        return @as(?[]u8, try allocator.dupe(
            u8,
            "Send feedback or report issues:\n\n" ++
                "  GitHub Issues: https://github.com/Softorize/zcode/issues\n" ++
                "  Create a new issue with:\n" ++
                "    - Description of the problem or feature request\n" ++
                "    - Steps to reproduce (if bug)\n" ++
                "    - Your zcode version (/version)\n" ++
                "    - Recent errors from /errors (paste the output)\n" ++
                "    - Your OS and model provider\n\n" ++
                "Or use /issue to create one directly from this session.",
        ));
    }

    // ── Recent errors (in-memory ring) ──
    //
    // Surface the in-memory error log written by core/error_log.zig
    // since pass 152. The ring captures the last 100 errors recorded
    // since process start so the user can attach them to a bug
    // report without re-running the failing command. See
    // core/error_log.zig and the reference's `getInMemoryErrors`
    // (utils/log.ts) for design notes on why this is separate from
    // the on-disk audit log.
    if (std.mem.eql(u8, command, "/errors") or std.mem.eql(u8, command, "/errors recent")) {
        return @as(?[]u8, try renderRecentErrors(allocator, 25));
    }
    if (std.mem.startsWith(u8, command, "/errors ")) {
        const arg = std.mem.trim(u8, command["/errors ".len..], " \t");
        if (std.mem.eql(u8, arg, "clear")) {
            const error_log = @import("core/error_log.zig");
            error_log.clear();
            return @as(?[]u8, try allocator.dupe(u8, "in-memory error log cleared"));
        }
        if (std.mem.eql(u8, arg, "count")) {
            const error_log = @import("core/error_log.zig");
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{d} error(s) in the in-memory ring (capacity 100)", .{error_log.count()}));
        }
        // Numeric argument = max count to render.
        if (std.fmt.parseInt(usize, arg, 10)) |max| {
            return @as(?[]u8, try renderRecentErrors(allocator, max));
        } else |_| {}
        return @as(?[]u8, try allocator.dupe(u8, "usage: /errors [N|clear|count]\n  /errors          show the most recent 25 errors\n  /errors N        show the most recent N errors\n  /errors clear    drop the in-memory ring\n  /errors count    show how many entries are stored"));
    }

    // ── Theme ──

    if (std.mem.eql(u8, command, "/theme") or std.mem.startsWith(u8, command, "/theme ")) {
        return handleThemeCommand(allocator, runtime, command);
    }

    // ── Onboarding ──

    if (std.mem.eql(u8, command, "/onboarding")) {
        return @as(?[]u8, try renderOnboarding(allocator, runtime));
    }

    // ── KAIROS background agent ──

    if (std.mem.eql(u8, command, "/kairos") or std.mem.startsWith(u8, command, "/kairos ")) {
        const kb = @import("core/kairos_brief.zig");
        const cwd = runtime.cwd;
        const rest = std.mem.trim(u8, command["/kairos".len..], " ");

        if (std.mem.startsWith(u8, rest, "approve ")) {
            const id = std.mem.trim(u8, rest["approve ".len..], " ");
            const proposals = try kb.listProposals(allocator, cwd);
            defer {
                for (proposals) |*p| p.deinit(allocator);
                allocator.free(proposals);
            }
            for (proposals) |p| {
                if (std.mem.eql(u8, p.id, id)) {
                    // Re-run the intent prompt live (re-derives against current
                    // state, through the normal interactive approval gate), then
                    // drop the proposal. See ADR 0008 / docs/KAIROS.md.
                    const intent = try allocator.dupe(u8, p.prompt);
                    defer allocator.free(intent);
                    _ = kb.removeProposal(allocator, cwd, id);
                    return @as(?[]u8, try runtime.handlePrompt(intent));
                }
            }
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "no proposal with id {s}", .{id}));
        }
        if (std.mem.startsWith(u8, rest, "dismiss ")) {
            const id = std.mem.trim(u8, rest["dismiss ".len..], " ");
            const ok = kb.removeProposal(allocator, cwd, id);
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} {s}", .{ if (ok) "dismissed" else "no proposal with id", id }));
        }
        if (std.mem.eql(u8, rest, "clear")) {
            kb.clearBrief(allocator, cwd);
            return @as(?[]u8, try allocator.dupe(u8, "kairos brief cleared"));
        }
        return @as(?[]u8, try renderKairosOverview(allocator, cwd));
    }

    // /loop [interval] <prompt> - schedule a recurring prompt and fire it once
    // now. Mirrors Claude Code's loop skill (immediate-fire + recurring cron).
    if (std.mem.eql(u8, command, "/loop") or std.mem.startsWith(u8, command, "/loop ")) {
        const td = @import("tools/tool_dispatch.zig");
        const args = std.mem.trim(u8, command["/loop".len..], " \t");
        if (args.len == 0) return @as(?[]u8, try allocator.dupe(u8, LOOP_USAGE));

        const parsed = parseLoopArgs(args);
        if (parsed.prompt.len == 0) return @as(?[]u8, try allocator.dupe(u8, LOOP_USAGE));

        var cron_buf: [40]u8 = undefined;
        const cron_expr = intervalToCron(&cron_buf, parsed.interval) orelse
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "couldn't parse interval '{s}'. Use Ns/Nm/Nh/Nd (e.g. 5m, 2h).", .{parsed.interval}));

        // Durable + recurring + project-tagged so the background KAIROS process
        // picks it up too (Claude Code's /loop is session-only; durable here is
        // a deliberate choice so the loop survives for KAIROS).
        const id = td.scheduleCron(allocator, cron_expr, parsed.prompt, true, true, runtime.cwd) catch |err| switch (err) {
            error.TooManyCronJobs => return @as(?[]u8, try allocator.dupe(u8, "Too many scheduled jobs (max 50). Cancel one with CronDelete first.")),
            else => return err,
        };
        const id_owned = try allocator.dupe(u8, id);
        defer allocator.free(id_owned);

        // Fire the prompt once now -- don't wait for the first cron tick.
        const fired = if (std.mem.startsWith(u8, parsed.prompt, "/"))
            ((try replCommandCallback(ctx, allocator, parsed.prompt)) orelse try allocator.dupe(u8, ""))
        else
            try runtime.handlePrompt(parsed.prompt);
        defer allocator.free(fired);

        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "Looping every {s} (cron \"{s}\", durable, job {s}). Auto-expires after 7 days; cancel with CronDelete {s}.\n\n{s}",
            .{ parsed.interval, cron_expr, id_owned, id_owned, fired },
        ));
    }

    // ── Memory consolidation ──

    if (std.mem.eql(u8, command, "/dream")) {
        const dream_mod = @import("core/dream.zig");

        if (!dream_mod.acquireLock(allocator).acquired) {
            return @as(?[]u8, try allocator.dupe(u8, "memory consolidation is already running (lock held)"));
        }
        // Always release the lock on exit. Previously any error between
        // acquireLock and the explicit releaseLock call (OOM in
        // buildDreamPrompt, provider failure in handlePrompt, allocPrint
        // failure in the summary) would leave the lockfile on disk
        // permanently blocking future /dream invocations.
        defer dream_mod.releaseLock(allocator);

        // Optimistically stamp the last-consolidation marker = now before the
        // skill runs (background-svc-06). If the manual run crashes or is
        // Ctrl-C'd mid-execution, the auto-dream time gate is still reset
        // rather than firing again immediately. The success-path releaseLock
        // above just refreshes the same timestamp.
        dream_mod.recordConsolidation(allocator);

        const prompt = try dream_mod.buildDreamPrompt(allocator);
        defer allocator.free(prompt);

        const result = try runtime.handlePrompt(prompt);
        defer allocator.free(result);

        const index_lines = dream_mod.countMemoryIndexLines(allocator);
        const summary = try std.fmt.allocPrint(allocator, "{s}\n\n--- memory consolidation complete (MEMORY.md: {d} lines) ---", .{ result, index_lines });
        return @as(?[]u8, summary);
    }

    // ── Quick utility commands ──

    if (std.mem.eql(u8, command, "/prompt") or std.mem.startsWith(u8, command, "/prompt ")) {
        return handlePromptInspectCommand(allocator, runtime, command);
    }

    if (std.mem.eql(u8, command, "/doctor")) {
        return @as(?[]u8, try runDoctorDiagnostics(allocator, runtime));
    }

    // #566: /stickers - open the sticker order page in the user's browser.
    // Direct port of reference src/commands/stickers/stickers.ts.
    if (std.mem.eql(u8, command, "/stickers")) {
        return @as(?[]u8, try openStickerPage(allocator));
    }

    // #566: /good-claude - record positive feedback. The reference's
    // good-claude command is a disabled stub (isEnabled: () => false);
    // zcode ships an actual handler that acknowledges the feedback.
    if (std.mem.eql(u8, command, "/good-claude")) {
        return @as(?[]u8, try allocator.dupe(u8, "Thanks! Noted. (Positive feedback recorded locally.)"));
    }

    if (std.mem.eql(u8, command, "/env") or std.mem.eql(u8, command, "/env info") or std.mem.eql(u8, command, "/env current")) {
        return @as(?[]u8, try renderEnvironmentInfo(allocator, runtime));
    }
    // Session env var management (ported from claude-code-main
    // src/utils/sessionEnvVars.ts). Values set here are applied
    // ONLY to spawned child processes (shell, grep, etc.) -- not
    // to zcode's own process environment. Use this to feed a
    // project's expected CI=true, NODE_ENV=test, GIT_AUTHOR_*,
    // or custom vars into subprocess commands without leaking
    // them back to the outer shell on exit.
    if (std.mem.eql(u8, command, "/env list") or std.mem.eql(u8, command, "/env show")) {
        const session_env = @import("core/session_env.zig");
        return @as(?[]u8, try session_env.formatList(allocator));
    }
    if (std.mem.eql(u8, command, "/env clear")) {
        const session_env = @import("core/session_env.zig");
        session_env.clear(allocator);
        return @as(?[]u8, try allocator.dupe(u8, "session env cleared"));
    }
    if (std.mem.startsWith(u8, command, "/env unset ")) {
        const session_env = @import("core/session_env.zig");
        const name = std.mem.trim(u8, command["/env unset ".len..], " \t\r\n");
        if (name.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /env unset <NAME>"));
        }
        session_env.unset(allocator, name);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "unset {s}", .{name}));
    }
    if (std.mem.startsWith(u8, command, "/env set ")) {
        const session_env = @import("core/session_env.zig");
        const kv = std.mem.trim(u8, command["/env set ".len..], " \t\r\n");
        if (kv.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /env set NAME=VALUE  (or: /env set NAME VALUE)"));
        }
        // Accept both `NAME=VALUE` and `NAME VALUE`. Quote the
        // VALUE side if you need whitespace to survive.
        var name: []const u8 = "";
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
            name = std.mem.trim(u8, kv[0..eq], " \t");
            value = kv[eq + 1 ..];
        } else if (std.mem.indexOfScalar(u8, kv, ' ')) |sp| {
            name = std.mem.trim(u8, kv[0..sp], " \t");
            value = std.mem.trim(u8, kv[sp + 1 ..], " \t");
        } else {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /env set NAME=VALUE  (missing '=' separator)"));
        }
        // Strip surrounding quotes on the value so users can
        // write `/env set MSG="hello world"` without literal
        // double quotes leaking into the subprocess.
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }
        session_env.set(allocator, name, value) catch |err| switch (err) {
            error.InvalidEnvVarName => return @as(?[]u8, try std.fmt.allocPrint(allocator, "invalid env var name: {s} (must be non-empty and contain no '=' or control chars)", .{name})),
            else => return err,
        };
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "set {s}={s}", .{ name, value }));
    }

    if (std.mem.eql(u8, command, "/fast")) {
        // Fast mode is always on when streaming is enabled.
        // This command is a no-op acknowledgment since streaming is the default.
        return @as(?[]u8, try allocator.dupe(
            u8,
            "fast mode: streaming is enabled by default\n" ++
                "  - Tokens display as they are generated\n" ++
                "  - Same model is used (no downgrade)\n" ++
                "  - Toggle streaming with: interactive_streaming in config",
        ));
    }

    if (std.mem.eql(u8, command, "/copy") or std.mem.startsWith(u8, command, "/copy ")) {
        // Copy the Nth-latest assistant response to the clipboard via
        // pbcopy / xclip / clip.exe. Ported from
        // claude-code-main/src/commands/copy/copy.tsx which supports
        // `/copy` (last response) and `/copy N` (N-th latest), which
        // is useful when the user wants to copy an earlier answer
        // after the model has produced a follow-up.
        //
        // Parsing:
        //   /copy    -> N=1 (the most recent assistant message)
        //   /copy 2  -> N=2 (the second most recent)
        //   /copy 0  -> treat as 1 (1-indexed; 0 is the common typo)
        //   /copy 3m -> syntax error
        const nth: usize = blk: {
            if (std.mem.eql(u8, command, "/copy")) break :blk 1;
            const arg = std.mem.trim(u8, command["/copy ".len..], " \t");
            if (arg.len == 0) break :blk 1;
            const parsed = std.fmt.parseInt(usize, arg, 10) catch {
                return @as(?[]u8, try std.fmt.allocPrint(
                    allocator,
                    "usage: /copy [N]\n  /copy      copies the most recent assistant response\n  /copy N    copies the Nth most recent (1-indexed, so /copy 2 is the answer BEFORE the latest)\nerror: could not parse '{s}' as a positive integer",
                    .{arg},
                ));
            };
            if (parsed == 0) break :blk 1;
            break :blk parsed;
        };

        // Walk backwards through history and grab the Nth assistant turn.
        var seen: usize = 0;
        var target: ?[]const u8 = null;
        var idx = runtime.history.len();
        while (idx > 0) {
            idx -= 1;
            if (runtime.history.at(idx).role != .assistant) continue;
            seen += 1;
            if (seen == nth) {
                target = runtime.history.at(idx).content;
                break;
            }
        }

        if (target) |content| {
            const clip_result = try copyToClipboard(allocator, content);
            defer allocator.free(clip_result);
            if (nth == 1) {
                return @as(?[]u8, try allocator.dupe(u8, clip_result));
            }
            // Annotate which Nth we copied so the user knows we
            // honored their index.
            return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "{s} (copied the {d}-latest assistant response)",
                .{ clip_result, nth },
            ));
        }

        // Not enough assistant responses. Tell the user what we saw.
        if (seen == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "no assistant response to copy"));
        }
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "only {d} assistant response{s} in history -- cannot copy the {d}-latest",
            .{ seen, if (seen == 1) @as([]const u8, "") else @as([]const u8, "s"), nth },
        ));
    }

    if (std.mem.eql(u8, command, "/clear") or std.mem.eql(u8, command, "/reset") or std.mem.eql(u8, command, "/new")) {
        return @as(?[]u8, try handleClearConversation(allocator, runtime));
    }

    // ── Files in context ──────────────────────────────────────
    //
    // Lists every file the model has Read (or Edited -- Edit refreshes
    // the tracker too) since process start. Ports the /files command
    // from claude-code-main/src/commands/files/. Useful when the user
    // wants to know "what do you have loaded right now?" without
    // having to scroll back through the transcript looking for Read
    // calls.
    //
    // Paths are reported relative to cwd so they're easy to scan.
    // Absolute paths outside the workspace fall through unchanged.
    if (std.mem.eql(u8, command, "/files") or std.mem.eql(u8, command, "/files list")) {
        return @as(?[]u8, try renderTrackedFiles(allocator, runtime.cwd));
    }

    if (std.mem.eql(u8, command, "/release-notes") or std.mem.eql(u8, command, "/releasenotes") or std.mem.eql(u8, command, "/changelog")) {
        return @as(?[]u8, try renderReleaseNotes(allocator, runtime));
    }

    if (std.mem.eql(u8, command, "/thinkback")) {
        return @as(?[]u8, try renderThinkback(allocator, runtime, 5));
    }
    if (std.mem.startsWith(u8, command, "/thinkback ")) {
        const arg = std.mem.trim(u8, command["/thinkback ".len..], " \t");
        const count = std.fmt.parseInt(usize, arg, 10) catch 5;
        return @as(?[]u8, try renderThinkback(allocator, runtime, count));
    }

    if (std.mem.startsWith(u8, command, "/rename ")) {
        const new_name = std.mem.trim(u8, command["/rename ".len..], " \t");
        if (new_name.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /rename <new-session-name>"));
        }
        // Persist the label in a sidecar file next to the session's
        // jsonl so /session list can render it alongside the id.
        // Previous behaviour appended a system turn which was
        // invisible in the session listing -- a functional no-op
        // from the user's point of view.
        try runtime.store.setLabel(runtime.session_id, new_name);
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "session {s} renamed to: {s}", .{ runtime.session_id, new_name }));
    }

    if (std.mem.eql(u8, command, "/rename")) {
        return @as(?[]u8, try allocator.dupe(u8, "usage: /rename <new-session-name>"));
    }

    // ── /add-dir ──────────────────────────────────────────────────
    // Register an additional workspace directory. Persisted across
    // sessions in `<XDG_STATE_HOME>/zcode/workspace-dirs.txt`.
    // Ported from claude-code-main/src/commands/add-dir.
    if (std.mem.eql(u8, command, "/add-dir") or std.mem.eql(u8, command, "/add-dir list")) {
        return @as(?[]u8, try workspace_dirs_mod.render(allocator));
    }
    if (std.mem.startsWith(u8, command, "/add-dir remove ")) {
        const arg = std.mem.trim(u8, command["/add-dir remove ".len..], " \t");
        if (arg.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /add-dir remove <index|absolute-path>"));
        const removed = workspace_dirs_mod.remove(allocator, arg) catch |err| return @as(?[]u8, try std.fmt.allocPrint(allocator, "/add-dir remove failed: {s}", .{@errorName(err)}));
        if (!removed) return @as(?[]u8, try std.fmt.allocPrint(allocator, "not found: {s}", .{arg}));
        runtime.prompt_sections_registry.invalidate(.workspace_dirs);
        // Refresh the sandbox's view of the extra roots so the removed dir is
        // no longer authorized mid-session (permissions-05).
        runtime.reloadAdditionalDirectories();
        return @as(?[]u8, try workspace_dirs_mod.render(allocator));
    }
    if (std.mem.startsWith(u8, command, "/add-dir ")) {
        const arg = std.mem.trim(u8, command["/add-dir ".len..], " \t");
        if (arg.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /add-dir <path>"));
        const added = workspace_dirs_mod.add(allocator, arg) catch |err| switch (err) {
            error.DirectoryNotFound => return @as(?[]u8, try std.fmt.allocPrint(allocator, "directory does not exist: {s}", .{arg})),
            error.InvalidDirectory => return @as(?[]u8, try allocator.dupe(u8, "usage: /add-dir <path>")),
            else => return @as(?[]u8, try std.fmt.allocPrint(allocator, "/add-dir failed: {s}", .{@errorName(err)})),
        };
        if (!added) return @as(?[]u8, try std.fmt.allocPrint(allocator, "already registered: {s}", .{arg}));
        runtime.prompt_sections_registry.invalidate(.workspace_dirs);
        // Refresh the sandbox's view of the extra roots so the newly-added dir
        // is authorized mid-session (permissions-05).
        runtime.reloadAdditionalDirectories();
        return @as(?[]u8, try workspace_dirs_mod.render(allocator));
    }

    // ── /tag ──────────────────────────────────────────────────────
    // Tag the current session with a freeform label. Tags are
    // stored as a sidecar file next to the session jsonl and
    // surface in /session list and /insights.
    if (std.mem.eql(u8, command, "/tag") or std.mem.eql(u8, command, "/tag list")) {
        const tags = try runtime.store.readTags(runtime.session_id);
        defer runtime.store.freeTags(tags);
        if (tags.len == 0) return @as(?[]u8, try allocator.dupe(u8, "session has no tags. add one with `/tag add <name>`."));
        var buf = std_io.StringBuilder.init(allocator);
        defer buf.deinit();
        try buf.writer().print("tags for {s}:\n", .{runtime.session_id});
        for (tags) |t| try buf.writer().print("  - {s}\n", .{t});
        return @as(?[]u8, try buf.toOwnedSlice());
    }
    if (std.mem.startsWith(u8, command, "/tag add ")) {
        const name = std.mem.trim(u8, command["/tag add ".len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /tag add <name>"));
        const added = try runtime.store.addTag(runtime.session_id, name);
        if (!added) return @as(?[]u8, try std.fmt.allocPrint(allocator, "tag already set: {s}", .{name}));
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "tagged session {s}: {s}", .{ runtime.session_id, name }));
    }
    if (std.mem.startsWith(u8, command, "/tag remove ") or std.mem.startsWith(u8, command, "/tag rm ")) {
        const prefix_len: usize = if (std.mem.startsWith(u8, command, "/tag remove ")) "/tag remove ".len else "/tag rm ".len;
        const name = std.mem.trim(u8, command[prefix_len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /tag remove <name>"));
        const removed = try runtime.store.removeTag(runtime.session_id, name);
        if (!removed) return @as(?[]u8, try std.fmt.allocPrint(allocator, "tag not present: {s}", .{name}));
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "removed tag {s}", .{name}));
    }

    // ── /pr-link ──────────────────────────────────────────────────
    // Record a PR URL against the current session (Phase 11 sessions-07).
    // Links are stored as a deduped newline-delimited sidecar next to the
    // session jsonl and feed the picker + agentic search.
    if (std.mem.eql(u8, command, "/pr-link") or std.mem.eql(u8, command, "/pr-link list")) {
        const links = try runtime.store.readPrLinks(runtime.session_id);
        defer runtime.store.freeTags(links);
        if (links.len == 0) return @as(?[]u8, try allocator.dupe(u8, "session has no PR links. add one with `/pr-link <url>`."));
        var buf = std_io.StringBuilder.init(allocator);
        defer buf.deinit();
        try buf.writer().print("PR links for {s}:\n", .{runtime.session_id});
        for (links) |l| try buf.writer().print("  - {s}\n", .{l});
        return @as(?[]u8, try buf.toOwnedSlice());
    }
    if (std.mem.startsWith(u8, command, "/pr-link ")) {
        const url = std.mem.trim(u8, command["/pr-link ".len..], " \t");
        if (url.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /pr-link <url>"));
        const added = try runtime.store.addPrLink(runtime.session_id, url);
        if (!added) return @as(?[]u8, try std.fmt.allocPrint(allocator, "PR link already recorded: {s}", .{url}));
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "linked session {s} to PR: {s}", .{ runtime.session_id, url }));
    }

    // ── /stats ────────────────────────────────────────────────────
    // Cross-session aggregate. Distinct from /cost which is
    // per-session and token-focused.
    if (std.mem.eql(u8, command, "/stats")) {
        const summaries = try stats_report.collect(allocator, runtime.store);
        defer stats_report.freeSummaries(allocator, summaries);
        return @as(?[]u8, try stats_report.renderStats(allocator, summaries));
    }

    // ── /insights ─────────────────────────────────────────────────
    // Richer analytics on top of the stats corpus.
    if (std.mem.eql(u8, command, "/insights")) {
        const summaries = try stats_report.collect(allocator, runtime.store);
        defer stats_report.freeSummaries(allocator, summaries);
        return @as(?[]u8, try stats_report.renderInsights(allocator, summaries));
    }

    // ── /summary ──────────────────────────────────────────────────
    // Condensed summary of the current session WITHOUT rewriting
    // history. Distinct from /compact which mutates the runtime
    // history to reclaim context.
    if (std.mem.eql(u8, command, "/summary")) {
        const display = try renderSessionSummary(allocator, runtime);
        // Phase 10 Task 6 (memory-05): /summary also persists distilled notes to
        // the per-session notes file via the constrained summarizer fork. The
        // inline stats display above is kept; the persist is best-effort and
        // appends a one-line confirmation when it wrote a file.
        if (runtime.manualSessionMemory()) |notes_path| {
            defer allocator.free(notes_path);
            const combined = try std.fmt.allocPrint(
                allocator,
                "{s}\n\nsession notes updated: {s}",
                .{ display, notes_path },
            );
            allocator.free(display);
            return @as(?[]u8, combined);
        }
        return @as(?[]u8, display);
    }

    // ── /break-cache ──────────────────────────────────────────────
    // Force the next model call to bypass prompt cache. One-shot:
    // clears itself after firing.
    if (std.mem.eql(u8, command, "/break-cache")) {
        runtime.skip_next_cache = true;
        return @as(?[]u8, try allocator.dupe(u8, "prompt cache bypass armed -- the next model call will ship without cache_control."));
    }

    // ── /login /logout ────────────────────────────────────────────
    // REPL-facing wrappers so users don't have to drop to a shell
    // for common auth lifecycle ops. The heavy lifting still lives
    // in the provider CLI path so this is a thin routing hint.
    if (std.mem.eql(u8, command, "/login")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "run `zcode provider login {s}` in a separate terminal to sign in.\nfor Anthropic OAuth specifically: `zcode provider login anthropic`.\ncurrent active provider: {s}",
            .{ runtime.active_provider, runtime.active_provider },
        ));
    }
    if (std.mem.eql(u8, command, "/logout")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "run `zcode provider logout {s}` in a separate terminal to clear stored credentials.",
            .{runtime.active_provider},
        ));
    }

    // ── /ide ──────────────────────────────────────────────────────
    if (std.mem.eql(u8, command, "/ide")) {
        return @as(?[]u8, try ide_detect.render(allocator));
    }

    // ── /terminal-setup ───────────────────────────────────────────
    if (std.mem.eql(u8, command, "/terminal-setup") or std.mem.eql(u8, command, "/terminalsetup") or std.mem.eql(u8, command, "/terminal_setup")) {
        return @as(?[]u8, try terminal_caps.render(allocator));
    }

    // ── /heapdump ─────────────────────────────────────────────────
    if (std.mem.eql(u8, command, "/heapdump")) {
        return @as(?[]u8, try heap_diag.render(allocator, runtime));
    }

    // ── /ctx-viz ──────────────────────────────────────────────────
    if (std.mem.eql(u8, command, "/ctx-viz") or std.mem.eql(u8, command, "/ctx_viz") or std.mem.eql(u8, command, "/ctxviz")) {
        return @as(?[]u8, try ctx_viz.render(allocator, runtime));
    }

    // ── /advisor ──────────────────────────────────────────────────
    // Advisor is an alias for review mode at the session scope.
    // Keeping it as a sugar command (rather than a separate flag)
    // means `/mode execution` and `/advisor off` agree on the state
    // without us having to keep two booleans in sync.
    if (std.mem.eql(u8, command, "/advisor") or std.mem.eql(u8, command, "/advisor status")) {
        const on = runtime.requested_mode != null and runtime.requested_mode.? == .review;
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "advisor mode: {s}\nuse `/advisor on` to enter (read-only, no filesystem or shell mutations).\nuse `/advisor off` to leave.",
            .{if (on) "on" else "off"},
        ));
    }
    if (std.mem.eql(u8, command, "/advisor on")) {
        runtime.requested_mode = .review;
        return @as(?[]u8, try allocator.dupe(u8, "advisor mode enabled. i will review and recommend but not edit or execute."));
    }
    if (std.mem.eql(u8, command, "/advisor off")) {
        runtime.requested_mode = null;
        return @as(?[]u8, try allocator.dupe(u8, "advisor mode disabled. regular execution mode restored."));
    }

    // ── /chrome ───────────────────────────────────────────────────
    // Thin passthrough to MCP-side browser tools if any are
    // registered. Mirrors the reference's `/chrome` which talks to
    // a companion browser extension.
    if (std.mem.eql(u8, command, "/chrome") or std.mem.eql(u8, command, "/chrome status")) {
        return @as(?[]u8, try renderChromeStatus(allocator, runtime));
    }

    // ── /autofix-pr ───────────────────────────────────────────────
    // Kick off a review-style prompt with an autofix directive
    // against the current branch diff. Uses the existing review
    // flow so findings and fixes stream back through the same
    // pipeline.
    if (std.mem.eql(u8, command, "/autofix-pr") or std.mem.eql(u8, command, "/autofix_pr")) {
        const prompt = try std.fmt.allocPrint(
            allocator,
            "You are in autofix-PR mode. Review the current branch against main, identify any bugs, test failures, missing error handling, and style violations, then APPLY concrete fixes using the Edit / Write tools. Keep the diff minimal. When done, run the project's test command (zig build test if present) and report pass/fail. If you cannot run tests, say so explicitly.",
            .{},
        );
        defer allocator.free(prompt);
        const out = try runtime.handlePromptWithModeAndReporter(prompt, null, .execution);
        return @as(?[]u8, out);
    }

    // Response language preference. Ported from claude-code-main/
    // src/constants/prompts.ts getLanguageSection. Users on a
    // non-English IME / locale want the model to reply in their
    // language without having to append "please answer in French"
    // to every prompt. Setting sticks for the whole session (via
    // the mutable runtime override) and gets re-injected into every
    // system prompt build; callers who want permanence can also
    // set `preferred_language = "fr"` in ~/.zcode/config.toml to
    // seed the session default.
    if (std.mem.eql(u8, command, "/lang") or std.mem.eql(u8, command, "/lang current")) {
        if (runtime.preferred_language.len > 0) {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "language: {s}", .{runtime.preferred_language}));
        }
        return @as(?[]u8, try allocator.dupe(u8, "language: (none; model will default to English)"));
    }
    if (std.mem.eql(u8, command, "/lang clear") or std.mem.eql(u8, command, "/lang none") or std.mem.eql(u8, command, "/lang off")) {
        allocator.free(runtime.preferred_language);
        runtime.preferred_language = try allocator.dupe(u8, "");
        return @as(?[]u8, try allocator.dupe(u8, "language cleared; model will default to English"));
    }
    if (std.mem.startsWith(u8, command, "/lang ")) {
        const lang = std.mem.trim(u8, command["/lang ".len..], " \t");
        if (lang.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /lang <language>  (e.g. /lang Spanish, /lang ja, /lang \"Brazilian Portuguese\")"));
        }
        if (lang.len > 64) {
            return @as(?[]u8, try allocator.dupe(u8, "language name too long (max 64 chars)"));
        }
        const unquoted = if (lang.len >= 2 and ((lang[0] == '"' and lang[lang.len - 1] == '"') or
            (lang[0] == '\'' and lang[lang.len - 1] == '\''))) lang[1 .. lang.len - 1] else lang;
        allocator.free(runtime.preferred_language);
        runtime.preferred_language = try allocator.dupe(u8, unquoted);
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "language set to: {s}\n(takes effect on the next turn; persists for this session. To keep across sessions set `preferred_language = \"{s}\"` in ~/.zcode/config.toml.)",
            .{ unquoted, unquoted },
        ));
    }

    // ── Advanced workflow commands ──

    if (std.mem.eql(u8, command, "/security-review") or std.mem.startsWith(u8, command, "/security-review ")) {
        const scope = if (std.mem.startsWith(u8, command, "/security-review "))
            std.mem.trim(u8, command["/security-review ".len..], " \t")
        else
            "";
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        try prompt_buf.writer().writeAll(
            "Perform a thorough security audit of this codebase. Check for:\n" ++
                "1. Command injection and shell escapes\n" ++
                "2. Path traversal and symlink attacks\n" ++
                "3. SQL injection, XSS, and OWASP Top 10\n" ++
                "4. Hardcoded secrets, API keys, and credentials\n" ++
                "5. Insecure deserialization\n" ++
                "6. Authentication and authorization bypasses\n" ++
                "7. Insecure cryptographic usage\n" ++
                "8. Dependency vulnerabilities\n" ++
                "9. Race conditions and TOCTOU bugs\n" ++
                "10. Information disclosure in error messages\n\n" ++
                "For each finding report: severity, file, line, description, and fix.\n",
        );
        if (scope.len > 0) try prompt_buf.writer().print("\nFocus on: {s}\n", .{scope});
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    // /btw <question>: a non-interrupting side question (commands-sweep-06).
    // Runs a one-shot model call with the current conversation as context but
    // does NOT append the question or answer to the transcript (handled in
    // runtime.runSideQuestion). Bare /btw returns usage.
    if (std.mem.eql(u8, command, "/btw") or std.mem.startsWith(u8, command, "/btw ")) {
        const question = if (std.mem.startsWith(u8, command, "/btw "))
            std.mem.trim(u8, command["/btw ".len..], " \t")
        else
            "";
        if (question.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "Usage: /btw <question> -- ask a quick side question without adding it to the conversation."));
        }
        const answer = (try runtime.runSideQuestion(question)) orelse
            return @as(?[]u8, try allocator.dupe(u8, "(no answer returned for the side question)"));
        return @as(?[]u8, answer);
    }

    if (std.mem.eql(u8, command, "/worktree") or std.mem.eql(u8, command, "/worktree list")) {
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "worktree", "list" }));
    }
    if (std.mem.startsWith(u8, command, "/worktree add ")) {
        const args = std.mem.trim(u8, command["/worktree add ".len..], " \t");
        return @as(?[]u8, try runGitCommandWithArgs(allocator, runtime.cwd, &.{ "git", "worktree", "add" }, args));
    }
    if (std.mem.startsWith(u8, command, "/worktree remove ")) {
        const path = std.mem.trim(u8, command["/worktree remove ".len..], " \t");
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "worktree", "remove", path }));
    }

    if (std.mem.eql(u8, command, "/share") or std.mem.startsWith(u8, command, "/share ")) {
        const filename = if (std.mem.startsWith(u8, command, "/share "))
            std.mem.trim(u8, command["/share ".len..], " \t")
        else
            "session-share.md";
        // Export as shareable markdown (same as /export but with a default name for sharing)
        return @as(?[]u8, try exportSession(allocator, runtime, filename));
    }

    if (std.mem.startsWith(u8, command, "/add-dir ")) {
        const dir_path = std.mem.trim(u8, command["/add-dir ".len..], " \t");
        if (dir_path.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /add-dir <path>"));
        }
        const abs = if (std.fs.path.isAbsolute(dir_path))
            try allocator.dupe(u8, dir_path)
        else
            try std.fs.path.join(allocator, &.{ runtime.cwd, dir_path });
        defer allocator.free(abs);
        // Verify directory exists
        std.Io.Dir.cwd().access(rt.io, abs, .{}) catch {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "directory not found: {s}", .{abs}));
        };
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "added working directory: {s}\nUse this path when searching for files or running commands in that directory.", .{abs}));
    }

    // ── Automation commands ──

    if (std.mem.eql(u8, command, "/bughunter") or std.mem.startsWith(u8, command, "/bughunter ")) {
        const scope = if (std.mem.startsWith(u8, command, "/bughunter "))
            std.mem.trim(u8, command["/bughunter ".len..], " \t")
        else
            "";
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        try prompt_buf.writer().writeAll(
            "Perform a thorough bug hunt on this codebase. Look for:\n" ++
                "1. Logic errors and off-by-one mistakes\n" ++
                "2. Memory leaks and resource leaks (unclosed files, missing defers)\n" ++
                "3. Error handling gaps (swallowed errors, missing error paths)\n" ++
                "4. Race conditions and concurrency issues\n" ++
                "5. Security vulnerabilities (injection, path traversal, etc.)\n" ++
                "6. Null/undefined access risks\n" ++
                "7. Dead code and unreachable paths\n\n" ++
                "For each bug found, report: file path, line number, severity (critical/high/medium/low), description, and suggested fix.\n" ++
                "Focus on real bugs, not style issues.\n",
        );
        if (scope.len > 0) {
            try prompt_buf.writer().print("\nFocus scope: {s}\n", .{scope});
        }
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    if (std.mem.eql(u8, command, "/ultraplan") or std.mem.startsWith(u8, command, "/ultraplan ")) {
        const task = if (std.mem.startsWith(u8, command, "/ultraplan "))
            std.mem.trim(u8, command["/ultraplan ".len..], " \t")
        else
            "";
        if (task.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /ultraplan <task description>\n\nRuns deep multi-step planning with investigation, risk analysis, and implementation strategy."));
        }
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        try prompt_buf.writer().print(
            "Create a comprehensive implementation plan for: {s}\n\n" ++
                "Follow this process:\n" ++
                "1. INVESTIGATE: Read all relevant code files to understand current state\n" ++
                "2. ANALYZE: Identify dependencies, risks, and edge cases\n" ++
                "3. DESIGN: Consider multiple approaches, pick the best one with reasoning\n" ++
                "4. PLAN: Create a step-by-step implementation plan with:\n" ++
                "   - Specific files to create/modify\n" ++
                "   - Key code changes with reasoning\n" ++
                "   - Test strategy\n" ++
                "   - Rollback plan\n" ++
                "5. VERIFY: Check the plan for completeness and consistency\n\n" ++
                "Use explore and plan agents for parallel investigation where appropriate.\n",
            .{task},
        );
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    if (std.mem.eql(u8, command, "/debug-tool-call")) {
        // Show the last tool call from history for debugging
        var last_tool_turn: ?[]const u8 = null;
        var idx = runtime.history.len();
        while (idx > 0) {
            idx -= 1;
            const turn = runtime.history.at(idx);
            if (turn.role == .tool) {
                last_tool_turn = turn.content;
                break;
            }
        }
        if (last_tool_turn) |content| {
            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();
            try out.writer().writeAll("=== Last Tool Call Result ===\n\n");
            const clipped = if (content.len > 8192) content[0..8192] else content;
            try out.writer().writeAll(clipped);
            if (content.len > 8192) {
                try out.writer().print("\n\n... truncated ({d} bytes total)", .{content.len});
            }
            return @as(?[]u8, try out.toOwnedSlice());
        }
        return @as(?[]u8, try allocator.dupe(u8, "no tool calls in current session history"));
    }

    // ── Git shortcut commands ──

    if (std.mem.eql(u8, command, "/diff")) {
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "diff", "--stat", "--summary" }));
    }
    if (std.mem.startsWith(u8, command, "/diff ")) {
        const raw_args = std.mem.trim(u8, command["/diff ".len..], " \t");
        return @as(?[]u8, try runGitCommandWithArgs(allocator, runtime.cwd, &.{ "git", "diff" }, raw_args));
    }

    // commands-sweep-02: reference `/branch` (alias `/fork`) forks the CURRENT
    // CONVERSATION at this point into a new session id with traceability back to
    // the source. It is a pure conversation operation, NOT git. `/fork` resolves
    // to `/branch` via command_canonical.toDispatch. The old git-branch helper is
    // re-homed below under `/git-branch` so the functionality is not lost.
    if (std.mem.eql(u8, command, "/branch") or std.mem.startsWith(u8, command, "/branch ")) {
        const raw_name = if (std.mem.startsWith(u8, command, "/branch "))
            std.mem.trim(u8, command["/branch ".len..], " \t")
        else
            "";
        return @as(?[]u8, try runtime.forkSession(if (raw_name.len > 0) raw_name else null));
    }
    if (std.mem.eql(u8, command, "/git-branch")) {
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "branch", "-vv" }));
    }
    if (std.mem.startsWith(u8, command, "/git-branch create ")) {
        const name = std.mem.trim(u8, command["/git-branch create ".len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /git-branch create <name>"));
        if (!git_ref.isSafeRefName(name)) return @as(?[]u8, try allocator.dupe(u8, "invalid branch name"));
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "checkout", "-b", name }));
    }
    if (std.mem.startsWith(u8, command, "/git-branch switch ")) {
        const name = std.mem.trim(u8, command["/git-branch switch ".len..], " \t");
        if (name.len == 0) return @as(?[]u8, try allocator.dupe(u8, "usage: /git-branch switch <name>"));
        if (!git_ref.isSafeRefName(name)) return @as(?[]u8, try allocator.dupe(u8, "invalid branch name"));
        return @as(?[]u8, try runGitCommand(allocator, runtime.cwd, &.{ "git", "checkout", name }));
    }

    if (std.mem.eql(u8, command, "/commit") or std.mem.startsWith(u8, command, "/commit ")) {
        const extra = if (std.mem.startsWith(u8, command, "/commit "))
            std.mem.trim(u8, command["/commit ".len..], " \t")
        else
            "";
        // Quick check: anything to commit?
        const status = try runGitCommand(allocator, runtime.cwd, &.{ "git", "status", "--short" });
        defer allocator.free(status);
        if (std.mem.trim(u8, status, " \t\r\n").len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "nothing to commit (working tree clean)"));
        }
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        const w = prompt_buf.writer();
        try w.writeAll(
            \\Review the current git changes and create a single commit.
            \\
            \\1. First, gather context by running these commands:
            \\   - git status
            \\   - git diff HEAD (to see staged and unstaged changes)
            \\   - git log --oneline -10 (to match the repo's commit message style)
            \\
            \\2. Git safety rules:
            \\   - NEVER update git config
            \\   - NEVER skip hooks (no --no-verify or --no-gpg-sign)
            \\   - ALWAYS create NEW commits, never use git commit --amend
            \\   - Do NOT commit files that likely contain secrets (.env, credentials, etc.)
            \\   - Never use interactive flags (-i) as they are not supported
            \\   - If there are no changes, do not create an empty commit
            \\
            \\3. Analyze all changes and draft a commit message:
            \\   - Look at recent commits to follow the repo's commit message style
            \\   - Summarize the nature of the changes (new feature, enhancement, bug fix, refactoring, etc.)
            \\   - Draft a concise (1-2 sentences) commit message focusing on "why" not "what"
            \\   - "add" = wholly new feature, "update" = enhancement, "fix" = bug fix
            \\
            \\4. Stage relevant files with git add (prefer specific files over git add -A)
            \\   and commit using HEREDOC syntax:
            \\   git commit -m "$(cat <<'EOF'
            \\   Your commit message here.
            \\
            \\   Co-Authored-By: zcode <noreply@zcode.dev>
            \\   EOF
            \\   )"
            \\
        );
        if (extra.len > 0) {
            try w.print("\nAdditional context from the user: {s}\n", .{extra});
        }
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    if (std.mem.eql(u8, command, "/pr") or std.mem.startsWith(u8, command, "/pr ")) {
        const context = if (std.mem.startsWith(u8, command, "/pr "))
            std.mem.trim(u8, command["/pr ".len..], " \t")
        else
            "";
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        const w = prompt_buf.writer();
        try w.writeAll(
            \\Create a pull request for the current branch.
            \\
            \\1. First, gather context by running these commands:
            \\   - git status (check for uncommitted changes)
            \\   - git branch --show-current (get current branch name)
            \\   - git log --oneline main..HEAD (see all commits on this branch)
            \\   - git diff main...HEAD (see the full diff against main)
            \\
            \\2. If there are uncommitted changes, commit them first.
            \\
            \\3. Push the branch to origin with: git push -u origin <branch>
            \\
            \\4. Create the PR using gh pr create:
            \\   - Keep the PR title short (under 70 characters)
            \\   - Write a clear description with a Summary section (1-3 bullet points)
            \\   - Use HEREDOC for the body to preserve formatting:
            \\     gh pr create --title "title" --body "$(cat <<'EOF'
            \\     ## Summary
            \\     - bullet points of changes
            \\     EOF
            \\     )"
            \\
        );
        if (context.len > 0) {
            try w.print("\nAdditional context from the user: {s}\n", .{context});
        }
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    if (std.mem.eql(u8, command, "/issue") or std.mem.startsWith(u8, command, "/issue ")) {
        const context = if (std.mem.startsWith(u8, command, "/issue "))
            std.mem.trim(u8, command["/issue ".len..], " \t")
        else
            "";
        var prompt_buf = std_io.StringBuilder.init(allocator);
        defer prompt_buf.deinit();
        try prompt_buf.writer().writeAll("Create a GitHub issue using gh issue create. ");
        if (context.len > 0) {
            try prompt_buf.writer().print("Context: {s}", .{context});
        } else {
            try prompt_buf.writer().writeAll("Ask me what the issue should be about.");
        }
        const prompt = try prompt_buf.toOwnedSlice();
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    // ── /statusline command (commands-07) ──
    //
    // Best-effort port of the reference statusline-setup prompt command. zcode
    // has no `statusline-setup` subagent type, so instead of spawning a named
    // subagent we dispatch a direct instruction prompt asking the model to write
    // a status-line spec into the zcode settings file. The renderer does not yet
    // read a configurable status line (see the phase out-of-scope notes), so this
    // wires the prompt only -- it does not by itself change the rendered bar.
    if (std.mem.eql(u8, command, "/statusline") or std.mem.startsWith(u8, command, "/statusline ")) {
        const hint = if (std.mem.startsWith(u8, command, "/statusline "))
            std.mem.trim(u8, command["/statusline ".len..], " \t")
        else
            "";
        const prompt = try buildStatuslinePrompt(allocator, hint);
        defer allocator.free(prompt);
        return @as(?[]u8, try runtime.handlePrompt(prompt));
    }

    // ── /init command ──

    if (std.mem.eql(u8, command, "/init")) {
        return @as(?[]u8, try runInitCommand(allocator, runtime));
    }

    // ── /permissions command ──

    if (std.mem.eql(u8, command, "/permissions") or std.mem.startsWith(u8, command, "/permissions ")) {
        const args = if (std.mem.startsWith(u8, command, "/permissions "))
            std.mem.trim(u8, command["/permissions ".len..], " \t")
        else
            "";
        return @as(?[]u8, try runPermissionsCommand(allocator, runtime, args));
    }

    // ── /export command ──

    if (std.mem.eql(u8, command, "/export") or std.mem.startsWith(u8, command, "/export ")) {
        if (std.mem.startsWith(u8, command, "/export ")) {
            const filename = std.mem.trim(u8, command["/export ".len..], " \t");
            return @as(?[]u8, try exportSession(allocator, runtime, filename));
        }
        // No name given: derive one from the first user prompt (or a
        // timestamp when there is no prompt). sessions-05.
        const derived = try deriveExportFilename(allocator, runtime);
        defer allocator.free(derived);
        return @as(?[]u8, try exportSession(allocator, runtime, derived));
    }

    // ── Custom command / skill fallthrough (commands-01) ──
    //
    // Last resort, AFTER every built-in arm above: typing `/deploy` runs
    // `~/.zcode/commands/deploy.md`; typing `/<skillname>` runs a user-invocable
    // skill -- no `/command`/`/skill` wrapper needed. Built-ins win because they
    // are matched first by construction; this block only sees names no built-in
    // claimed, so a user file named `help.md` can never shadow `/help`.
    if (command.len > 1 and command[0] == '/') {
        const outcome = try resolveCustomOrSkill(allocator, runtime.cwd, command, runtime.session_id);
        switch (outcome) {
            .none => {}, // fall through to the unknown-command path below
            .message => |msg| return @as(?[]u8, msg),
            .prompt => |prompt| {
                defer allocator.free(prompt);
                return @as(?[]u8, try runtime.handlePromptWithModeAndReporter(prompt, null, .execution));
            },
        }
    }

    return null;
}

/// Result of resolving a `/<name>` slash command against custom commands and
/// user-invocable skills. Kept pure (no runtime, no dispatch) so the resolution
/// logic is unit-testable without a full REPL harness.
pub const ResolveOutcome = union(enum) {
    /// Neither a custom command nor a skill matched -- let the caller fall
    /// through to the existing unknown-command UX.
    none,
    /// A rendered prompt to dispatch through the agent runtime. Owned slice;
    /// the caller frees it after dispatch.
    prompt: []u8,
    /// A direct one-line message to show the user (e.g. a skill that exists but
    /// is not user-invocable). Owned slice; the caller returns it as-is.
    message: []u8,
};

/// Resolve `command` (a leading-slash token, e.g. `/deploy staging`) against the
/// custom-commands registry and then user-invocable skills. Resolution order
/// mirrors the reference precedence: custom commands first, then skills.
/// Built-ins are matched by the caller BEFORE this runs, so they always win.
///
/// Returns `.prompt` with an owned rendered prompt on a match, `.message` for a
/// skill that exists but is not user-invocable, and `.none` when nothing matches
/// (so the caller's unknown-command path still fires).
pub fn resolveCustomOrSkill(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8, session_id: []const u8) !ResolveOutcome {
    if (command.len < 2 or command[0] != '/') return .none;

    // Split `/deploy staging` into name `deploy` and args `staging`. Split on
    // the first space only; a namespaced name like `frontend:build` keeps its
    // colon (Task 3 produces those) because we never split on colon.
    const rest = command[1..];
    const name = if (std.mem.indexOfScalar(u8, rest, ' ')) |sp|
        std.mem.trim(u8, rest[0..sp], " \t")
    else
        std.mem.trim(u8, rest, " \t");
    const args = if (std.mem.indexOfScalar(u8, rest, ' ')) |sp|
        std.mem.trim(u8, rest[sp + 1 ..], " \t")
    else
        "";

    if (name.len == 0) return .none;

    // 1. Custom commands. `findByName` errors with CommandNotFound when absent;
    //    treat that (and only that) as a miss so genuine errors still surface.
    if (commands_mod.renderRun(allocator, cwd, name, args)) |prompt| {
        // Record the invocation for usage-frequency ranking (misc-utils-15).
        skill_usage_mod.recordSkill(allocator, name);
        return .{ .prompt = prompt };
    } else |err| switch (err) {
        error.CommandNotFound => {},
        else => return err,
    }

    // 2. Skills. `findByName` returns null when absent. A skill that exists but
    //    is not user-invocable returns a message rather than falling through to
    //    "unknown command" -- it tells the user why their `/name` did nothing.
    if (try skills_mod.findByName(allocator, cwd, name)) |found| {
        var skill = found;
        defer skill.deinit(allocator);
        if (!skill.user_invocable) {
            return .{ .message = try std.fmt.allocPrint(
                allocator,
                "skill '{s}' is not user-invocable",
                .{name},
            ) };
        }
        const prompt = try skills_mod.renderRun(allocator, cwd, name, args, session_id);
        // Record the invocation for usage-frequency ranking (misc-utils-15).
        skill_usage_mod.recordSkill(allocator, name);
        return .{ .prompt = prompt };
    }

    return .none;
}

/// Build the `/statusline` instruction prompt (commands-07). `hint` is the
/// optional trailing text the user typed after `/statusline`; when empty we
/// fall back to the reference default of configuring from the shell PS1.
///
/// Kept pure (allocator + hint only, no runtime, no disk I/O) so the prompt
/// wording is unit-testable without a full REPL. The settings paths named here
/// are the ones zcode actually uses (`~/.zcode/settings.json` for the user
/// scope, `.claude/settings.json` for the workspace scope), not the reference's
/// `~/.claude/settings.json`.
pub fn buildStatuslinePrompt(allocator: std.mem.Allocator, hint: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, hint, " \t");
    const directive = if (trimmed.len > 0)
        trimmed
    else
        "Configure my status line from my shell PS1 configuration";

    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().writeAll("Configure the zcode status line. ");
    try buf.writer().print("{s}. ", .{directive});
    try buf.writer().writeAll(
        "Inspect the user's shell PS1 configuration if it helps, then write the " ++
            "status line configuration to the appropriate settings file " ++
            "(the user-scope ~/.zcode/settings.json, or the workspace-scope " ++
            ".claude/settings.json). Do not break any existing settings; preserve " ++
            "the rest of the file and only add or update the status line entry.",
    );
    return buf.toOwnedSlice();
}

fn runPermissionsCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, args: []const u8) ![]u8 {
    if (args.len == 0 or std.mem.eql(u8, args, "status")) {
        return std.fmt.allocPrint(
            allocator,
            "permissions:\n" ++
                "  approval_mode: {s}\n" ++
                "  sandbox: {s}\n" ++
                "  auto_approve_high: {}\n" ++
                "  yolo_mode: {}\n" ++
                "  strict_mode: {}\n" ++
                "  rule_file: {s}\n" ++
                "  persistent_rules: {d}\n\n" ++
                "Persistent rules are evaluated before approval mode; deny wins, then ask, then allow.\n" ++
                "Policy BLOCKED and sandbox denials still win over persistent allow rules.\n\n" ++
                "Usage:\n" ++
                "  /permissions list\n" ++
                "  /permissions lint\n" ++
                "  /permissions add [--workspace] <allow|deny|ask> <tool|*> [args-contains]\n" ++
                "  /permissions replace [--workspace] <allow|deny|ask> [tool[:args] ...]\n" ++
                "  /permissions remove <index>\n" ++
                "  /permissions mode <tiered-auto|manual|strict|acceptEdits|plan|bypassPermissions|dontAsk>\n" ++
                "  /permissions add-dir <path>\n" ++
                "  /permissions remove-dir <index|path>\n" ++
                "  /permissions explain <tool|*> [args]",
            .{
                runtime.cfg.approval_mode,
                runtime.cfg.sandbox,
                runtime.auto_approve_high,
                runtime.yolo_mode,
                runtime.strict,
                permissionRulesPathForDisplay(runtime),
                runtime.permission_rules.rules.items.len,
            },
        );
    }

    if (std.mem.eql(u8, args, "list")) {
        return formatPermissionRuleList(allocator, runtime);
    }

    if (std.mem.eql(u8, args, "lint")) {
        return formatPermissionRuleLint(allocator, runtime);
    }

    if (std.mem.startsWith(u8, args, "add ") or std.mem.eql(u8, args, "add")) {
        return addPermissionRule(allocator, runtime, std.mem.trim(u8, args["add".len..], " \t"));
    }

    // Order matters: check "remove-dir" before "remove " so the dir form is not
    // swallowed by the plain remove prefix.
    if (std.mem.startsWith(u8, args, "remove-dir ") or std.mem.eql(u8, args, "remove-dir")) {
        return removePermissionDir(allocator, runtime, std.mem.trim(u8, args["remove-dir".len..], " \t"));
    }

    if (std.mem.startsWith(u8, args, "remove ") or std.mem.eql(u8, args, "remove")) {
        return removePermissionRule(allocator, runtime, std.mem.trim(u8, args["remove".len..], " \t"));
    }

    if (std.mem.startsWith(u8, args, "replace ") or std.mem.eql(u8, args, "replace")) {
        return replacePermissionRules(allocator, runtime, std.mem.trim(u8, args["replace".len..], " \t"));
    }

    if (std.mem.startsWith(u8, args, "mode ") or std.mem.eql(u8, args, "mode")) {
        return setPermissionMode(allocator, runtime, std.mem.trim(u8, args["mode".len..], " \t"));
    }

    if (std.mem.startsWith(u8, args, "add-dir ") or std.mem.eql(u8, args, "add-dir")) {
        return addPermissionDir(allocator, runtime, std.mem.trim(u8, args["add-dir".len..], " \t"));
    }

    if (std.mem.startsWith(u8, args, "explain ") or std.mem.eql(u8, args, "explain")) {
        return explainPermissionRule(allocator, runtime, std.mem.trim(u8, args["explain".len..], " \t"));
    }

    return std.fmt.allocPrint(
        allocator,
        "unknown /permissions subcommand: {s}\n\nTry `/permissions`, `/permissions list`, `/permissions lint`, `/permissions add`, `/permissions replace`, `/permissions remove`, `/permissions mode`, `/permissions add-dir`, `/permissions remove-dir`, or `/permissions explain`.",
        .{args},
    );
}

fn permissionRulesPathForDisplay(runtime: *const AgentRuntime) []const u8 {
    return if (runtime.permission_rules_path.len > 0) runtime.permission_rules_path else "<unavailable>";
}

fn formatPermissionRuleList(allocator: std.mem.Allocator, runtime: *const AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    try writer.print("permission rules: {d}\n", .{runtime.permission_rules.rules.items.len});
    try writer.writeAll("precedence: deny wins, then ask, then allow\n");
    try writer.print("file: {s}\n", .{permissionRulesPathForDisplay(runtime)});
    if (runtime.permission_rules.rules.items.len == 0) {
        try writer.writeAll("\nNo persistent permission rules are configured.");
        return out.toOwnedSlice();
    }

    for (runtime.permission_rules.rules.items, 0..) |rule, index| {
        try writer.writeByte('\n');
        try writePermissionRuleLine(writer, index, &rule);
    }

    // Append an unreachable-rule hint so users notice shadowed allow rules
    // without having to run `/permissions lint` blindly.
    const lint_buf = try allocator.alloc(shadow_detection_mod.Shadow, runtime.permission_rules.rules.items.len);
    defer allocator.free(lint_buf);
    const shadows = shadow_detection_mod.detect(runtime.permission_rules.rules.items, lint_buf);
    if (shadows.len > 0) {
        try writer.print("\n\n{d} unreachable rule(s) - run /permissions lint", .{shadows.len});
    }

    return out.toOwnedSlice();
}

/// `/permissions lint` reports allow rules made unreachable by a tool-wide deny
/// (severe) or tool-wide ask rule for the same tool, with a fix suggestion.
/// Mirrors the reference `detectUnreachableRules` report.
fn formatPermissionRuleLint(allocator: std.mem.Allocator, runtime: *const AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const writer = out.writer();

    const rules = runtime.permission_rules.rules.items;
    const lint_buf = try allocator.alloc(shadow_detection_mod.Shadow, rules.len);
    defer allocator.free(lint_buf);
    const shadows = shadow_detection_mod.detect(rules, lint_buf);

    if (shadows.len == 0) {
        try writer.writeAll("permission lint: no unreachable rules found");
        return out.toOwnedSlice();
    }

    try writer.print("permission lint: {d} unreachable rule(s)\n", .{shadows.len});
    for (shadows) |shadow| {
        const shadowed = &rules[shadow.shadowed_index];
        const shadower = &rules[shadow.shadower_index];
        const kind_word = switch (shadow.kind) {
            .deny => "deny",
            .ask => "ask",
        };
        const blocked_word = switch (shadow.kind) {
            .deny => "blocked by",
            .ask => "shadowed by",
        };
        try writer.print("\n  rule #{d} (allow ", .{shadow.shadowed_index + 1});
        try writePermissionRuleSummary(writer, shadowed);
        try writer.print(") is {s} tool-wide {s} {s}", .{ blocked_word, kind_word, shadower.tool });
        if (shadower.source_label.len > 0) {
            try writer.print(" from {s}", .{shadower.source_label});
        }
        try writer.print("\n    fix: remove the \"{s}\" {s} rule, or remove the specific allow rule", .{ shadower.tool, kind_word });
    }

    return out.toOwnedSlice();
}

fn addPermissionRule(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    if (runtime.permission_rules_path.len == 0) {
        return allocator.dupe(u8, "permission rule file is unavailable in this runtime");
    }

    var rest = raw_args;
    var workspace_scope = false;
    if (takeToken(rest)) |token| {
        if (std.mem.eql(u8, token.value, "--workspace")) {
            workspace_scope = true;
            rest = token.rest;
        }
    }

    const action_token = takeToken(rest) orelse return allocator.dupe(u8, "usage: /permissions add [--workspace] <allow|deny|ask> <tool|*> [args-contains]");
    const action = permission_rules_mod.Action.parse(action_token.value) orelse
        return std.fmt.allocPrint(allocator, "invalid permission action: {s}\nexpected one of: allow, deny, ask", .{action_token.value});
    const tool_token = takeToken(action_token.rest) orelse return allocator.dupe(u8, "usage: /permissions add [--workspace] <allow|deny|ask> <tool|*> [args-contains]");
    const args_contains = std.mem.trim(u8, tool_token.rest, " \t");
    const scope: permission_rules_mod.ScopeSpec = if (workspace_scope)
        .{ .workspace = runtime.cwd }
    else
        .global;

    const original_len = runtime.permission_rules.rules.items.len;
    try runtime.permission_rules.addRule(action, scope, tool_token.value, args_contains, runtime.permission_rules_path, 0, "user");
    errdefer if (runtime.permission_rules.rules.items.len > original_len) {
        runtime.permission_rules.removeAt(original_len) catch {};
    };
    try persistRuntimePermissionRules(runtime);

    const summary = try formatSinglePermissionRuleForReturn(allocator, &runtime.permission_rules.rules.items[runtime.permission_rules.rules.items.len - 1]);
    defer allocator.free(summary);
    return std.fmt.allocPrint(
        allocator,
        "added permission rule #{d}\n{s}",
        .{ runtime.permission_rules.rules.items.len, summary },
    );
}

fn removePermissionRule(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    if (runtime.permission_rules_path.len == 0) {
        return allocator.dupe(u8, "permission rule file is unavailable in this runtime");
    }
    const index_token = takeToken(raw_args) orelse return allocator.dupe(u8, "usage: /permissions remove <index>");
    if (index_token.rest.len != 0) return allocator.dupe(u8, "usage: /permissions remove <index>");
    const one_based = std.fmt.parseUnsigned(usize, index_token.value, 10) catch
        return std.fmt.allocPrint(allocator, "invalid permission rule index: {s}", .{index_token.value});
    if (one_based == 0 or one_based > runtime.permission_rules.rules.items.len) {
        return std.fmt.allocPrint(allocator, "permission rule index out of range: {d}", .{one_based});
    }

    try runtime.permission_rules.removeAt(one_based - 1);
    try persistRuntimePermissionRules(runtime);
    return std.fmt.allocPrint(allocator, "removed permission rule #{d}", .{one_based});
}

/// `/permissions replace [--workspace] <allow|deny|ask> [tool[:args] ...]`
/// Bulk-replaces every "user"-source rule of the given action with the supplied
/// set, then persists. Each space-separated token after the action is one rule:
/// `Bash` (tool-wide) or `Bash:git commit*` (the part after the first `:` is
/// args_contains, with no further splitting so the args may themselves contain
/// `:`). An empty replacement set removes all user rules of that action.
fn replacePermissionRules(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    if (runtime.permission_rules_path.len == 0) {
        return allocator.dupe(u8, "permission rule file is unavailable in this runtime");
    }

    var rest = raw_args;
    var workspace_scope = false;
    if (takeToken(rest)) |token| {
        if (std.mem.eql(u8, token.value, "--workspace")) {
            workspace_scope = true;
            rest = token.rest;
        }
    }

    const action_token = takeToken(rest) orelse
        return allocator.dupe(u8, "usage: /permissions replace [--workspace] <allow|deny|ask> [tool[:args] ...]");
    const action = permission_rules_mod.Action.parse(action_token.value) orelse
        return std.fmt.allocPrint(allocator, "invalid permission action: {s}\nexpected one of: allow, deny, ask", .{action_token.value});

    const scope: permission_rules_mod.ScopeSpec = if (workspace_scope)
        .{ .workspace = runtime.cwd }
    else
        .global;

    // Parse the remaining whitespace-separated tokens into RuleSpecs. The specs
    // borrow into `raw_args` (no copy needed); replaceRules dupes them.
    var specs = std.array_list.Managed(permission_rules_mod.RuleSpec).init(allocator);
    defer specs.deinit();
    var token_rest = action_token.rest;
    while (takeToken(token_rest)) |token| {
        token_rest = token.rest;
        if (std.mem.indexOfScalar(u8, token.value, ':')) |colon| {
            try specs.append(.{ .tool = token.value[0..colon], .args_contains = token.value[colon + 1 ..] });
        } else {
            try specs.append(.{ .tool = token.value, .args_contains = "" });
        }
    }

    try runtime.permission_rules.replaceRules(action, scope, "user", specs.items);
    try persistRuntimePermissionRules(runtime);

    return std.fmt.allocPrint(
        allocator,
        "replaced {s} rules: {d} rule(s) now active for this action+source",
        .{ action.toString(), specs.items.len },
    );
}

/// `/permissions mode <mode>` updates the active approval mode and persists it
/// to the user config (config.toml `approval_mode`). Accepts both zcode's legacy
/// modes (tiered-auto / manual / strict) and the Claude Code reference mode
/// names (acceptEdits / plan / bypassPermissions / dontAsk and hyphen variants).
fn setPermissionMode(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    const mode_token = takeToken(raw_args) orelse return allocator.dupe(
        u8,
        "usage: /permissions mode <tiered-auto|manual|strict|acceptEdits|plan|bypassPermissions|dontAsk>",
    );
    if (mode_token.rest.len != 0) return allocator.dupe(
        u8,
        "usage: /permissions mode <tiered-auto|manual|strict|acceptEdits|plan|bypassPermissions|dontAsk>",
    );

    const requested = mode_token.value;
    const is_legacy = std.ascii.eqlIgnoreCase(requested, "tiered-auto") or
        std.ascii.eqlIgnoreCase(requested, "manual") or
        std.ascii.eqlIgnoreCase(requested, "strict");
    if (!is_legacy and !permission_decision_mod.isReferenceModeName(requested)) {
        return std.fmt.allocPrint(
            allocator,
            "invalid permission mode: {s}\nexpected one of: tiered-auto, manual, strict, acceptEdits, plan, bypassPermissions, dontAsk",
            .{requested},
        );
    }

    // Canonicalize to lowercase to match the config_parse normalization for
    // approval_mode (it stores lowercase, e.g. `tiered-auto`).
    const lowered = try std.ascii.allocLowerString(allocator, requested);
    defer allocator.free(lowered);

    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    try mutable_cfg.setOwnedString(allocator, &mutable_cfg.approval_mode, lowered);
    config_parse.persistUserConfigField(allocator, "approval_mode", lowered) catch |err| {
        std.log.warn("failed to persist approval_mode setting: {s}", .{@errorName(err)});
        return std.fmt.allocPrint(
            allocator,
            "permission mode set to {s} for this session (persisting to config failed: {s})",
            .{ lowered, @errorName(err) },
        );
    };

    return std.fmt.allocPrint(allocator, "permission mode set to {s} (saved to config)", .{lowered});
}

/// `/permissions add-dir <path>` routes to the shared workspace-dirs store so
/// the additional-working-directory list stays a single source of truth shared
/// with sandbox authorization (Task 7).
fn addPermissionDir(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    if (raw_args.len == 0) return allocator.dupe(u8, "usage: /permissions add-dir <path>");
    const added = workspace_dirs_mod.add(allocator, raw_args) catch |err| switch (err) {
        error.DirectoryNotFound => return std.fmt.allocPrint(allocator, "/permissions add-dir: no such directory: {s}", .{raw_args}),
        error.InvalidDirectory => return allocator.dupe(u8, "usage: /permissions add-dir <path>"),
        else => return std.fmt.allocPrint(allocator, "/permissions add-dir failed: {s}", .{@errorName(err)}),
    };
    runtime.prompt_sections_registry.invalidate(.workspace_dirs);
    if (!added) {
        return std.fmt.allocPrint(allocator, "directory already registered: {s}", .{raw_args});
    }
    return workspace_dirs_mod.render(allocator);
}

/// `/permissions remove-dir <index|path>` routes to the shared workspace-dirs
/// store, mirroring `/add-dir remove`.
fn removePermissionDir(allocator: std.mem.Allocator, runtime: *AgentRuntime, raw_args: []const u8) ![]u8 {
    if (raw_args.len == 0) return allocator.dupe(u8, "usage: /permissions remove-dir <index|path>");
    const removed = workspace_dirs_mod.remove(allocator, raw_args) catch |err|
        return std.fmt.allocPrint(allocator, "/permissions remove-dir failed: {s}", .{@errorName(err)});
    runtime.prompt_sections_registry.invalidate(.workspace_dirs);
    if (!removed) {
        return std.fmt.allocPrint(allocator, "no matching workspace directory: {s}", .{raw_args});
    }
    return workspace_dirs_mod.render(allocator);
}

fn explainPermissionRule(allocator: std.mem.Allocator, runtime: *const AgentRuntime, raw_args: []const u8) ![]u8 {
    const tool_token = takeToken(raw_args) orelse return allocator.dupe(u8, "usage: /permissions explain <tool|*> [args]");
    const tool_args = std.mem.trim(u8, tool_token.rest, " \t");
    if (runtime.permission_rules.match(runtime.shell_cwd, tool_token.value, tool_args)) |matched| {
        var out = std_io.StringBuilder.init(allocator);
        errdefer out.deinit();
        const writer = out.writer();
        try writer.writeAll("matched permission rule:\n");
        try writePermissionRuleLine(writer, matched.index, matched.rule);
        try writer.print("\n\neffective_action: {s}", .{matched.rule.action.toString()});

        // Structured decision-reason taxonomy (permissions-14). Render the
        // matched rule as a reference-style `rule` reason so `/permissions
        // explain` speaks the same vocabulary as the blocked-trace output.
        const rule_string = try permission_rule_string_mod.toString(allocator, .{
            .tool_name = matched.rule.tool,
            .rule_content = if (matched.rule.args_contains.len > 0) matched.rule.args_contains else null,
        });
        defer allocator.free(rule_string);
        const source_label = if (matched.rule.source_label.len > 0) matched.rule.source_label else "settings";
        const reason_msg = try permission_reason_mod.format(allocator, tool_token.value, .{ .rule = .{
            .rule_string = rule_string,
            .source = source_label,
        } });
        defer allocator.free(reason_msg);
        try writer.print("\nreason: {s}", .{reason_msg});

        return out.toOwnedSlice();
    }

    return std.fmt.allocPrint(
        allocator,
        "no persistent permission rule matched tool={s} args=\"{s}\"\nnormal approval mode applies: {s}",
        .{ tool_token.value, tool_args, runtime.cfg.approval_mode },
    );
}

fn persistRuntimePermissionRules(runtime: *AgentRuntime) !void {
    try runtime.permission_rules.saveToFile(runtime.permission_rules_path);
    _ = try runtime.permission_rules.reloadFromFile(runtime.permission_rules_path);
}

fn formatSinglePermissionRuleForReturn(allocator: std.mem.Allocator, rule: *const permission_rules_mod.Rule) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    try writePermissionRuleSummary(out.writer(), rule);
    return out.toOwnedSlice();
}

fn writePermissionRuleLine(writer: anytype, index: usize, rule: *const permission_rules_mod.Rule) !void {
    try writer.print("  {d}. ", .{index + 1});
    try writePermissionRuleSummary(writer, rule);
    if (rule.source_path.len > 0) {
        if (rule.source_line > 0) {
            try writer.print(" source={s}:{d}", .{ rule.source_path, rule.source_line });
        } else {
            try writer.print(" source={s}", .{rule.source_path});
        }
    }
}

fn writePermissionRuleSummary(writer: anytype, rule: *const permission_rules_mod.Rule) !void {
    try writer.print("{s} tool={s}", .{ rule.action.toString(), rule.tool });
    if (rule.args_contains.len > 0) {
        try writer.print(" args_contains=\"{s}\"", .{rule.args_contains});
    } else {
        try writer.writeAll(" args_contains=<any>");
    }
    try writer.writeAll(" scope=");
    switch (rule.scope) {
        .global => try writer.writeAll("global"),
        .workspace => |path| try writer.print("workspace:{s}", .{path}),
    }
}

const ParsedToken = struct {
    value: []const u8,
    rest: []const u8,
};

fn takeToken(input: []const u8) ?ParsedToken {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return null;
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') : (end += 1) {}
    return .{
        .value = trimmed[0..end],
        .rest = std.mem.trim(u8, trimmed[end..], " \t"),
    };
}

/// Run a git command with a fixed prefix argv plus user-provided space-separated args.
fn runGitCommandWithArgs(allocator: std.mem.Allocator, cwd: []const u8, prefix: []const []const u8, user_args: []const u8) ![]u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    for (prefix) |arg| try argv.append(arg);
    var parts = std.mem.tokenizeAny(u8, user_args, " \t");
    while (parts.next()) |part| try argv.append(part);
    return runGitCommand(allocator, cwd, argv.items);
}

fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        const error_hints = @import("core/error_hints.zig");
        return error_hints.formatUiError(allocator, "git error", err);
    };
    defer allocator.free(result.stderr);

    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => {
            allocator.free(result.stdout);
            return allocator.dupe(u8, "git command terminated abnormally");
        },
    };

    if (code != 0) {
        defer allocator.free(result.stdout);
        const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
        if (stderr_trimmed.len > 0) {
            return std.fmt.allocPrint(allocator, "git error (exit {d}):\n{s}", .{ code, stderr_trimmed });
        }
        return std.fmt.allocPrint(allocator, "git error (exit {d})", .{code});
    }

    return result.stdout;
}

/// Ported from Claude Code's OLD_INIT_PROMPT
/// (claude-code-main/src/commands/init.ts). The reference's wording is
/// load-bearing: the exclude-list ("do not repeat yourself", "do not
/// make up `Common Development Tasks`") keeps the model from
/// hallucinating generic boilerplate, and the "pick up existing AI
/// configs" clause is how Cursor/Copilot rules get mirrored into the
/// zcode context instead of being silently ignored. Adapted: CLAUDE.md
/// -> ZCODE.md so the one-shot prompt targets the right file for this
/// project without breaking the reference's guidance structure.
const INIT_PROMPT =
    "Please analyze this codebase and create a ZCODE.md file, which will be given to future instances of zcode to operate in this repository.\n" ++
    "\n" ++
    "What to add:\n" ++
    "1. Commands that will be commonly used, such as how to build, lint, and run tests. Include the necessary commands to develop in this codebase, such as how to run a single test.\n" ++
    "2. High-level code architecture and structure so that future instances can be productive more quickly. Focus on the \"big picture\" architecture that requires reading multiple files to understand.\n" ++
    "\n" ++
    "Usage notes:\n" ++
    "- If there's already a ZCODE.md, suggest improvements to it. Do not silently overwrite it.\n" ++
    "- When you make the initial ZCODE.md, do not repeat yourself and do not include obvious instructions like \"Provide helpful error messages to users\", \"Write unit tests for all new utilities\", \"Never include sensitive information (API keys, tokens) in code or commits\".\n" ++
    "- Avoid listing every component or file structure that can be easily discovered.\n" ++
    "- Don't include generic development practices.\n" ++
    "- If there are Cursor rules (in .cursor/rules/ or .cursorrules), Copilot rules (in .github/copilot-instructions.md), Windsurf rules (.windsurfrules), Cline rules (.clinerules), or AGENTS.md, make sure to include the important parts.\n" ++
    "- If there is a README.md, make sure to include the important parts.\n" ++
    "- If there is a CLAUDE.md, lift over anything still relevant so a zcode-only contributor gets the same context.\n" ++
    "- Do not make up information such as \"Common Development Tasks\", \"Tips for Development\", \"Support and Documentation\" unless this is expressly included in other files that you read.\n" ++
    "- Be sure to prefix the file with the following text:\n" ++
    "\n" ++
    "```\n" ++
    "# ZCODE.md\n" ++
    "\n" ++
    "This file provides guidance to zcode when working with code in this repository.\n" ++
    "```\n";

fn runInitCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    _ = allocator;
    return runtime.handlePrompt(INIT_PROMPT);
}

/// Derive a default `/export` filename from the first user prompt (sanitized
/// slug) or a timestamp when there is no prompt. sessions-05. Caller owns the
/// returned slice. The derived name is still run through `exportSession`'s
/// path-traversal guard, but the slugifier already rejects `.`/`/`/`..`.
fn deriveExportFilename(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const session_export_md = @import("core/session_export_md.zig");
    var first_prompt: []const u8 = "";
    for (runtime.history.view()) |turn| {
        if (turn.role == .user) {
            first_prompt = turn.content;
            break;
        }
    }
    return session_export_md.defaultFilename(allocator, first_prompt, clock.nowSeconds());
}

fn exportSession(allocator: std.mem.Allocator, runtime: *AgentRuntime, filename: []const u8) ![]u8 {
    // Reject absolute paths and `..` traversal outright. The REPL
    // `/export` command used to accept any path and happily overwrite
    // files outside the workspace (e.g. `/export /etc/passwd`), which
    // is a user-controlled file write that bypasses the sandbox's
    // path-containment check. Exports must land inside the current
    // workspace.
    if (std.fs.path.isAbsolute(filename)) {
        return allocator.dupe(u8, "export failed: output path must be inside the workspace (absolute paths rejected)");
    }
    var segs = std.mem.splitAny(u8, filename, "/\\");
    while (segs.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) {
            return allocator.dupe(u8, "export failed: output path must stay inside the workspace (.. segments rejected)");
        }
    }

    const path = try std.fs.path.join(allocator, &.{ runtime.cwd, filename });
    defer allocator.free(path);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll("# Session Export\n\n");
    try out.writer().print("Model: {s}/{s}\n", .{ runtime.active_provider, runtime.active_model });
    try out.writer().print("Session: {s}\n\n---\n", .{runtime.session_id});

    // Route the per-turn rendering through the shared markdown exporter so
    // tool calls/results get the structured (fenced) treatment. sessions-05.
    // toMarkdown emits its own `# <title>` line first; we drop it (we already
    // wrote a `# Session Export` header above) and append the rest.
    const session_export_md = @import("core/session_export_md.zig");
    const body_md = try session_export_md.toMarkdown(allocator, "", runtime.history.view());
    defer allocator.free(body_md);
    const after_title = if (std.mem.indexOfScalar(u8, body_md, '\n')) |nl| body_md[nl + 1 ..] else body_md;
    try out.writer().writeAll(after_title);

    const content = try out.toOwnedSlice();
    defer allocator.free(content);

    const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, content);

    return std.fmt.allocPrint(allocator, "session exported to {s} ({d} turns)", .{ filename, runtime.history.len() });
}

/// Write a skeleton `ZCODE.md` in the current shell cwd. Refuses
/// to overwrite an existing file so a second `/init` can't wipe
/// the user's edits. Ports the reference `/init` behaviour from
/// claude-code-main, adapted to zcode's file name convention
/// (ZCODE.md instead of CLAUDE.md).
fn handleInitSkeleton(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const target_path = try std.fs.path.join(allocator, &.{ runtime.shell_cwd, "ZCODE.md" });
    defer allocator.free(target_path);

    // Refuse to clobber an existing file.
    if (std.Io.Dir.cwd().access(rt.io, target_path, .{})) |_| {
        return std.fmt.allocPrint(
            allocator,
            "/init: ZCODE.md already exists at {s}. Remove or rename it first if you want a fresh skeleton.",
            .{target_path},
        );
    } else |_| {}

    // The skeleton: header + four sections with short hint lines.
    // Intentionally sparse -- the user (or the model on a follow-up
    // turn) fills in the bodies based on the actual project.
    const skeleton =
        "# ZCODE.md\n" ++
        "\n" ++
        "zcode reads this file into the system prompt at startup so every turn " ++
        "has the same context about this project. Fill in the sections below " ++
        "with facts that the model would otherwise have to rediscover.\n" ++
        "\n" ++
        "## Project\n" ++
        "\n" ++
        "One paragraph describing what this project is, who uses it, and why it exists. " ++
        "Stay concrete: \"Terminal-first AI coding assistant for Zig projects\" beats \"A tool for users.\"\n" ++
        "\n" ++
        "## Build & test\n" ++
        "\n" ++
        "- Build: `<your build command>`\n" ++
        "- Test: `<your test command>`\n" ++
        "- Lint / format: `<your format command>`\n" ++
        "- Run locally: `<how to start it in dev>`\n" ++
        "\n" ++
        "## Architecture\n" ++
        "\n" ++
        "Name the 3-6 top-level components and how they connect. Example:\n" ++
        "\n" ++
        "- `src/foo/` -- request parsing\n" ++
        "- `src/bar/` -- business logic\n" ++
        "- `src/baz/` -- persistence layer\n" ++
        "\n" ++
        "Flag anything non-obvious (custom allocators, concurrency model, ownership rules).\n" ++
        "\n" ++
        "## Conventions\n" ++
        "\n" ++
        "Code style rules, naming patterns, commit-message format, branch naming, " ++
        "PR-review expectations -- anything a new contributor would ask about.\n" ++
        "\n" ++
        "## Gotchas\n" ++
        "\n" ++
        "Non-obvious footguns, known broken configurations, tests that require a " ++
        "specific environment, external services that must be running locally, etc. " ++
        "One bullet per gotcha, short and specific.\n";

    const file = try std.Io.Dir.cwd().createFile(rt.io, target_path, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, skeleton);

    return std.fmt.allocPrint(
        allocator,
        "/init: wrote ZCODE.md skeleton to {s} ({d} bytes). Edit it to describe your project -- zcode will read it into the system prompt on every turn.",
        .{ target_path, skeleton.len },
    );
}

fn renderOnboarding(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const onboarding_ctx = onboarding_mod.RuntimeContext{
        .active_provider = runtime.active_provider,
        .active_model = runtime.active_model,
    };
    const snapshot = onboarding_mod.buildSnapshot(runtime.cwd, onboarding_ctx);

    // Show the per-workspace onboarding checklist first so returning
    // users immediately see "ZCODE.md: yes" instead of scrolling past
    // the full setup walkthrough. Ported from projectOnboardingState.ts.
    const checklist = onboarding_mod.renderChecklist(allocator, runtime.cwd, onboarding_ctx) catch "";
    defer if (checklist.len > 0) allocator.free(checklist);
    if (checklist.len > 0) {
        try out.writer().writeAll("--- Workspace onboarding ---\n\n");
        try out.writer().writeAll(checklist);
        try out.writer().writeAll("\n");
    }

    if (!snapshot.needsProviderGuide()) {
        try out.writer().writeAll("--- Next steps ---\n\n");
        if (snapshot.workspace_empty) {
            try out.writer().writeAll("Your current model is ready. Clone a repo or ask zcode to scaffold a project before starting a coding session.\n\n");
        } else if (!snapshot.has_instruction_file) {
            try out.writer().writeAll("Your current model is ready. Run /init to create ZCODE.md for this workspace so zcode has project-specific instructions.\n\n");
        } else {
            try out.writer().writeAll("Your current model is ready. Ask for a task, or use the commands below to inspect the environment and switch models.\n\n");
        }
        try out.writer().writeAll(
            "--- Quick Start ---\n\n" ++
                "  /help               - see all commands\n" ++
                "  /model              - pick or switch models\n" ++
                "  /doctor             - check your setup\n" ++
                "  /env                - inspect current configuration\n",
        );
        if (!snapshot.workspace_empty and !snapshot.has_instruction_file) {
            try out.writer().writeAll("  /init               - create ZCODE.md for your project\n");
        }
        return out.toOwnedSlice();
    }

    if (snapshot.provider_configured and !snapshot.api_key_ready) {
        if (onboarding_mod.providerApiKeyEnvVar(runtime.active_provider)) |env_name| {
            try out.writer().print(
                "Next step: the active provider {s} needs {s}. Export that env var or use /model to switch providers.\n\n",
                .{ runtime.active_provider, env_name },
            );
        }
    } else if (!snapshot.provider_configured) {
        try out.writer().writeAll("Next step: choose a provider/model with /model, then finish any required credentials.\n\n");
    }

    try out.writer().writeAll(
        "=== Welcome to zcode! ===\n\n" ++
            "zcode is an AI coding agent that runs directly in your terminal.\n" ++
            "It supports multiple AI providers and local models.\n\n" ++
            "--- Provider Setup ---\n\n" ++
            "Choose your provider and set the API key:\n\n" ++
            "  LOCAL (Ollama - free, runs on your machine):\n" ++
            "    1. Install Ollama: https://ollama.ai\n" ++
            "    2. Pull a model: ollama pull qwen3:32b\n" ++
            "    3. Start server: ollama serve\n" ++
            "    4. Set in zcode: /model local/qwen3:32b\n\n" ++
            "  OPENROUTER (many models, pay-per-use):\n" ++
            "    1. Sign up: https://openrouter.ai\n" ++
            "    2. Get API key from dashboard\n" ++
            "    3. export OPENROUTER_API_KEY=sk-or-...\n" ++
            "    4. Set in zcode: /model openrouter/<model-name>\n\n" ++
            "  OPENAI:\n" ++
            "    1. Get key: https://platform.openai.com/api-keys\n" ++
            "    2. export OPENAI_API_KEY=sk-...\n" ++
            "    3. Set in zcode: /model openai/gpt-4.1\n\n" ++
            "  ANTHROPIC:\n" ++
            "    1. Get key: https://console.anthropic.com\n" ++
            "    2. export ANTHROPIC_API_KEY=sk-ant-...\n" ++
            "    3. Set in zcode: /model anthropic/claude-sonnet-4-5\n\n" ++
            "  DEEPSEEK:\n" ++
            "    1. Get key: https://platform.deepseek.com\n" ++
            "    2. export DEEPSEEK_API_KEY=sk-...\n" ++
            "    3. Set in zcode: /model deepseek/deepseek-chat\n\n" ++
            "  GEMINI (Google):\n" ++
            "    1. Get key: https://aistudio.google.com\n" ++
            "    2. export GEMINI_API_KEY=...\n" ++
            "    3. Set in zcode: /model gemini/gemini-2.5-flash\n\n" ++
            "  GROQ (fast inference):\n" ++
            "    1. Get key: https://console.groq.com\n" ++
            "    2. export GROQ_API_KEY=gsk_...\n" ++
            "    3. Set in zcode: /model groq/llama-3.3-70b\n\n" ++
            "--- Quick Start ---\n\n" ++
            "  /model              - pick a model interactively\n" ++
            "  /init               - create ZCODE.md for your project\n" ++
            "  /help               - see all commands\n" ++
            "  /doctor             - check your setup\n" ++
            "  /env                - see current configuration\n\n" ++
            "--- Config File ---\n\n" ++
            "  Your config is at: ~/.zcode/config.toml\n" ++
            "  Project config at: .zcode/config.toml\n" ++
            "  Local overrides at: .zcode/settings.local.toml (git-ignored)\n\n" ++
            "Example config:\n" ++
            "  default_provider = local\n" ++
            "  default_model = qwen3:32b\n" ++
            "  local_base_url = http://127.0.0.1:11434\n" ++
            "  model_context_window = 32768\n",
    );

    return out.toOwnedSlice();
}

const DoctorSummary = struct {
    pass: usize = 0,
    warn: usize = 0,
    fail: usize = 0,
};

const DoctorSeverity = enum {
    pass,
    warn,
    fail,

    fn label(self: DoctorSeverity) []const u8 {
        return switch (self) {
            .pass => "PASS",
            .warn => "WARN",
            .fail => "FAIL",
        };
    }
};

fn writeRankedDoctorChecks(allocator: std.mem.Allocator, runtime: *AgentRuntime, out: *std_io.StringBuilder) !void {
    var summary: DoctorSummary = .{};
    try out.writer().writeAll("ranked checks:\n");

    const git_ok = which_mod.exists(allocator, "git");
    const curl_ok = which_mod.exists(allocator, "curl");
    ripgrep_status.testOnce(allocator);
    const rg_snap = ripgrep_status.snapshot();
    const rg_ok = rg_snap != null and rg_snap.?.working;
    const shell_sandbox_ok = shellSandboxReady(runtime.cfg.sandbox);

    if (!git_ok) try writeDoctorCheck(out, &summary, .fail, "git", "not found on PATH", "Install git; zcode uses it for diffs, status, commits, PR context, and review.");
    if (!rg_ok) try writeDoctorCheck(out, &summary, .fail, "ripgrep", "not working", "Install a working `rg`; Grep and repository search quality depend on it.");
    if (!curl_ok) try writeDoctorCheck(out, &summary, .fail, "curl", "not found on PATH", "Install curl or configure a provider path that does not require curl-backed probes.");
    if (!shell_sandbox_ok) try writeDoctorCheck(out, &summary, .fail, "shell sandbox", "enforced backend unavailable", "Install sandbox-exec/bwrap or switch to a supported sandbox profile; avoid unsafe legacy fallback.");

    if (std.mem.eql(u8, runtime.cfg.sandbox, "danger-full-access")) {
        try writeDoctorCheck(out, &summary, .warn, "sandbox", "danger-full-access disables isolation", "Use workspace-write or read-only for normal enterprise operation.");
    } else if (sandbox_mod.allowLegacyUnisolatedShell() and sandbox_mod.requiresEnforcedShellSandbox(runtime.cfg.sandbox) and !sandbox_mod.hasShellSandboxBackend(runtime.cfg.sandbox)) {
        try writeDoctorCheck(out, &summary, .warn, "shell sandbox", "legacy unisolated fallback enabled", "Unset ZCODE_ALLOW_UNISOLATED_SHELL after installing a real shell sandbox backend.");
    }

    if (runtime.cfg.session_retention_days == 0) {
        try writeDoctorCheck(out, &summary, .warn, "retention", "sessions never expire", "Set session_retention_days in config or managed policy.");
    }
    if (runtime.cfg.tool_output_artifact_threshold_bytes == 0) {
        try writeDoctorCheck(out, &summary, .warn, "tool artifacts", "large-output artifacting disabled", "Set tool_output_artifact_threshold_bytes to a positive value, for example 65536.");
    }
    if (runtime.permission_rules.rules.items.len == 0) {
        try writeDoctorCheck(out, &summary, .warn, "permissions", "no persistent permission rules configured", "Use `/permissions add` to persist explicit allow/deny/ask rules for high-risk tools.");
    } else {
        // Unreachable-rule detection: flag content-keyed allow rules shadowed by
        // a tool-wide deny/ask for the same tool.
        const lint_buf = try allocator.alloc(shadow_detection_mod.Shadow, runtime.permission_rules.rules.items.len);
        defer allocator.free(lint_buf);
        const shadows = shadow_detection_mod.detect(runtime.permission_rules.rules.items, lint_buf);
        if (shadows.len > 0) {
            const shadow_status = try std.fmt.allocPrint(allocator, "{d} unreachable permission rule(s)", .{shadows.len});
            defer allocator.free(shadow_status);
            try writeDoctorCheck(out, &summary, .warn, "permissions", shadow_status, "Run `/permissions lint` to see which allow rules are shadowed by tool-wide deny/ask rules.");
        }
    }
    if (std.mem.indexOf(u8, build_options.app_version, "dirty") != null) {
        try writeDoctorCheck(out, &summary, .warn, "version", "dirty build", "Use a clean, signed release build for enterprise rollout.");
    }

    var ide = ide_detect.detect(allocator) catch null;
    defer if (ide) |*det| det.deinit(allocator);
    if (ide) |det| {
        if (det.kind == .unknown) {
            try writeDoctorCheck(out, &summary, .warn, "IDE bridge", "no recognized editor or terminal integration", "Run `/ide` and install the VS Code extension if editor callbacks are needed.");
        }
    } else {
        try writeDoctorCheck(out, &summary, .warn, "IDE bridge", "detection failed", "Run `/ide` from the target terminal to inspect environment variables.");
    }

    if (keychain_mod.Backend.detect() == .file_fallback) {
        try writeDoctorCheck(out, &summary, .warn, "keychain", "using file fallback backend", "Prefer OS keychain backends for developer workstations; file fallback is for CI/minimal hosts.");
    }

    if (git_ok) try writeDoctorCheck(out, &summary, .pass, "git", "available", "");
    if (rg_ok) try writeDoctorCheck(out, &summary, .pass, "ripgrep", "working", "");
    if (curl_ok) try writeDoctorCheck(out, &summary, .pass, "curl", "available", "");
    if (shell_sandbox_ok and !std.mem.eql(u8, runtime.cfg.sandbox, "danger-full-access")) try writeDoctorCheck(out, &summary, .pass, "shell sandbox", "ready", "");
    if (runtime.cfg.tool_output_artifact_threshold_bytes > 0) try writeDoctorCheck(out, &summary, .pass, "tool artifacts", "enabled", "");
    if (runtime.permission_rules.rules.items.len > 0) try writeDoctorCheck(out, &summary, .pass, "permissions", "persistent rules configured", "");
    if (runtime.cfg.session_retention_days > 0) try writeDoctorCheck(out, &summary, .pass, "retention", "session cleanup configured", "");

    try out.writer().print(
        "summary: {d} pass, {d} warn, {d} fail\n\n",
        .{ summary.pass, summary.warn, summary.fail },
    );
}

fn writeDoctorCheck(
    out: *std_io.StringBuilder,
    summary: *DoctorSummary,
    severity: DoctorSeverity,
    area: []const u8,
    status: []const u8,
    action: []const u8,
) !void {
    switch (severity) {
        .pass => summary.pass += 1,
        .warn => summary.warn += 1,
        .fail => summary.fail += 1,
    }
    try out.writer().print("[{s}] {s}: {s}", .{ severity.label(), area, status });
    if (action.len > 0) try out.writer().print(" -- {s}", .{action});
    try out.writer().writeByte('\n');
}

fn shellSandboxReady(profile: []const u8) bool {
    if (std.mem.eql(u8, profile, "danger-full-access")) return true;
    if (!sandbox_mod.requiresEnforcedShellSandbox(profile)) return true;
    return sandbox_mod.hasShellSandboxBackend(profile);
}

/// #566: Open the Claude Code sticker order page in the user's browser.
/// Direct port of reference src/commands/stickers/stickers.ts call().
fn openStickerPage(allocator: std.mem.Allocator) ![]u8 {
    const url = "https://www.stickermule.com/claudecode";
    const argv = switch (@import("builtin").os.tag) {
        .macos => [_][]const u8{ "open", url },
        .linux => [_][]const u8{ "xdg-open", url },
        else => return allocator.dupe(u8, "Sticker page URL: " ++ url),
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch {
        return allocator.dupe(u8, "Failed to open browser. Visit: " ++ url);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) {
        return allocator.dupe(u8, "Failed to open browser. Visit: " ++ url);
    }
    return allocator.dupe(u8, "Opening sticker page in browser...");
}

fn runDoctorDiagnostics(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const metrics_mod = @import("core/metrics.zig");
    const format_mod_local = @import("core/format.zig");

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll("=== zcode doctor ===\n\n");

    // Runtime identity
    try out.writer().print("zcode version: {s}\n", .{build_options.app_version});
    try out.writer().print("platform: {s}\n", .{platform_mod.detect().toString()});
    var os_buf: [192]u8 = undefined;
    try out.writer().print("os_version: {s}\n", .{platform_mod.writeOsVersion(&os_buf)});
    try out.writer().print("shell: {s}\n", .{platform_mod.shellBasename()});
    try out.writer().print("cwd: {s}\n", .{runtime.cwd});
    try out.writer().print("provider: {s}\n", .{runtime.active_provider});
    try out.writer().print("model: {s}\n\n", .{runtime.active_model});

    try writeRankedDoctorChecks(allocator, runtime, &out);

    // External tool probes. Previously spawned `<tool> --version` for
    // every probe, which cost a subprocess-spawn per tool and, for
    // things like `gh --version`, could hit the network via the
    // tool's own auto-update / auth check path. Now we walk $PATH
    // natively via core/which so /doctor is cheap and side-effect
    // free. Ported from claude-code-main/src/utils/which.ts.
    const git_ok = which_mod.exists(allocator, "git");
    try out.writer().print("[{s}] git: {s}\n", .{ if (git_ok) "ok" else "MISSING", if (git_ok) "installed" else "not found - install git" });
    // ripgrep gets the deeper probe: instead of just checking
    // PATH, we run `rg --version` once and verify the banner so
    // we catch broken installs (wrong arch, missing libc, name
    // collision with a non-rg program) that a PATH-only check
    // would happily pass. Result is cached process-wide so the
    // probe runs at most once. Ported from claude-code-main/src/
    // utils/ripgrep.ts testRipgrepOnFirstUse.
    const rg_line = try ripgrep_status.formatForDoctor(allocator);
    defer allocator.free(rg_line);
    try out.writer().print("{s}\n", .{rg_line});
    const curl_ok = which_mod.exists(allocator, "curl");
    try out.writer().print("[{s}] curl: {s}\n", .{ if (curl_ok) "ok" else "MISSING", if (curl_ok) "installed" else "not found - install curl" });
    const gh_ok = which_mod.exists(allocator, "gh");
    if (gh_ok) {
        // gh is on PATH; surface the auth state too. The check uses
        // `gh auth token` (local-only, no network) and discards the
        // token. See tools/git_extra.zig ghAuthStatus.
        const gh_status = git_extra.ghAuthStatus(allocator);
        const gh_desc = switch (gh_status) {
            .authenticated => "installed, authenticated",
            .not_authenticated => "installed, not authenticated - run `gh auth login` for /pr, /issue",
            .not_installed => "installed", // unreachable in practice (which found it)
        };
        const gh_tag = if (gh_status == .authenticated) "ok" else "warn";
        try out.writer().print("[{s}] gh CLI: {s}\n", .{ gh_tag, gh_desc });
    } else {
        try out.writer().print("[optional] gh CLI: not found - install gh for /pr, /issue\n", .{});
    }

    // Repo freshness: when the working repo last fetched > 7 days ago, the
    // checked-out tree (and any committed CLAUDE.md context) may be stale.
    // Reads `.git/FETCH_HEAD` mtime directly (no git subprocess). See
    // core/git_fs.zig lastFetchAgeSeconds. The full deep-link provenance banner
    // is deferred; only this FETCH_HEAD-age note is surfaced here.
    if (git_fs.resolveGitDir(allocator, runtime.cwd)) |git_dir| {
        defer allocator.free(git_dir);
        if (git_fs.lastFetchAgeSeconds(allocator, git_dir)) |age_seconds| {
            const seven_days_seconds: i64 = 7 * 24 * 60 * 60;
            if (age_seconds > seven_days_seconds) {
                const days = @divFloor(age_seconds, 24 * 60 * 60);
                try out.writer().print("[warn] repo freshness: last fetch was {d} days ago - repo may be stale; CLAUDE.md context could be outdated\n", .{days});
            }
        }
    }

    // Model connectivity
    try out.writer().writeAll("\nmodel connectivity:\n");
    if (std.mem.eql(u8, runtime.active_provider, "local") or std.mem.eql(u8, runtime.active_provider, "ollama")) {
        const ollama_url = try std.fmt.allocPrint(allocator, "{s}/api/tags", .{runtime.cfg.local_base_url});
        defer allocator.free(ollama_url);
        const ollama_ok = checkCommand(allocator, &.{ "curl", "-s", "--max-time", "3", ollama_url });
        try out.writer().print("[{s}] Ollama: {s}\n", .{ if (ollama_ok) "ok" else "FAIL", if (ollama_ok) "reachable" else "not reachable - check ollama serve" });
    } else {
        try out.writer().print("[skip] cloud provider ({s}) - check API key env var\n", .{runtime.active_provider});
    }

    // TLS / custom CA bundle status. Enterprise users behind
    // TLS-intercepting proxies (Zscaler, Cisco Umbrella, etc) need
    // a custom CA bundle. zcode shells out to curl which picks up
    // CURL_CA_BUNDLE and SSL_CERT_FILE automatically from the
    // inherited environment -- showing the active values here lets
    // users confirm their corporate proxy cert is being applied
    // without having to guess. Ported in spirit from
    // claude-code-main/src/utils/caCerts.ts + caCertsConfig.ts
    // which does the same job via Node's NODE_EXTRA_CA_CERTS.
    try out.writer().writeAll("\nTLS / CA bundle:\n");
    const curl_ca = @import("core/env.zig").getenv("CURL_CA_BUNDLE");
    const ssl_cert = @import("core/env.zig").getenv("SSL_CERT_FILE");
    const node_extra = @import("core/env.zig").getenv("NODE_EXTRA_CA_CERTS");
    if (curl_ca) |val| {
        try out.writer().print("  CURL_CA_BUNDLE: {s}\n", .{val});
    } else {
        try out.writer().writeAll("  CURL_CA_BUNDLE: (not set)\n");
    }
    if (ssl_cert) |val| {
        try out.writer().print("  SSL_CERT_FILE: {s}\n", .{val});
    } else {
        try out.writer().writeAll("  SSL_CERT_FILE: (not set)\n");
    }
    if (node_extra) |val| {
        try out.writer().print("  NODE_EXTRA_CA_CERTS: {s}\n", .{val});
    } else {
        try out.writer().writeAll("  NODE_EXTRA_CA_CERTS: (not set)\n");
    }
    if (curl_ca == null and ssl_cert == null) {
        try out.writer().writeAll("  [hint] behind a corporate TLS proxy? export CURL_CA_BUNDLE=/path/to/ca.pem\n");
    }

    // HTTP proxy status. Same ergonomics rationale as the TLS block
    // above -- curl inherits HTTPS_PROXY / HTTP_PROXY / NO_PROXY
    // automatically from the environment, so zcode's HTTP path
    // "just works" through a corporate proxy when the user has the
    // env vars set in their shell. Surfacing them here lets users
    // confirm the proxy is active and see which URLs will bypass it.
    // Ported in spirit from claude-code-main/src/utils/proxy.ts
    // getProxyUrl / getNoProxy, with curl-honouring lowercase
    // variants checked first (curl's own precedence order).
    try out.writer().writeAll("\nHTTP proxy:\n");
    const https_proxy_lc = @import("core/env.zig").getenv("https_proxy");
    const https_proxy_uc = @import("core/env.zig").getenv("HTTPS_PROXY");
    const http_proxy_lc = @import("core/env.zig").getenv("http_proxy");
    const http_proxy_uc = @import("core/env.zig").getenv("HTTP_PROXY");
    const no_proxy_lc = @import("core/env.zig").getenv("no_proxy");
    const no_proxy_uc = @import("core/env.zig").getenv("NO_PROXY");
    // Matches proxy.ts getProxyUrl precedence: lowercase https wins
    // first, then uppercase, then http variants. curl honours the
    // same order internally so this reflects reality.
    const active_proxy: ?[]const u8 = https_proxy_lc orelse https_proxy_uc orelse http_proxy_lc orelse http_proxy_uc;
    const active_no_proxy: ?[]const u8 = no_proxy_lc orelse no_proxy_uc;
    if (active_proxy) |val| {
        try out.writer().print("  active proxy: {s}\n", .{val});
        if (active_no_proxy) |np| {
            try out.writer().print("  no_proxy:     {s}\n", .{np});
        } else {
            try out.writer().writeAll("  no_proxy:     (not set)\n");
        }
    } else {
        try out.writer().writeAll("  active proxy: (none)\n");
    }

    // Onboarding checklist (pass 88)
    try out.writer().writeAll("\nworkspace onboarding:\n");
    const checklist = onboarding_mod.renderChecklist(allocator, runtime.cwd, .{
        .active_provider = runtime.active_provider,
        .active_model = runtime.active_model,
    }) catch "";
    defer if (checklist.len > 0) allocator.free(checklist);
    if (checklist.len > 0) {
        try out.writer().writeAll(checklist);
    } else {
        try out.writer().writeAll("  (up to date)\n");
    }

    // Instruction file size warnings. Pass 135. Ported from
    // claude-code-main/src/utils/doctorContextWarnings.ts
    // checkClaudeMdFiles. ZCODE.md / CLAUDE.md / AGENTS.md and
    // their .local / .claude variants ride along on EVERY prompt
    // and eat input tokens. When one grows past 40 000 bytes the
    // user usually doesn't realise they're paying that cost on
    // every turn. The warning surfaces the file path and size so
    // they can split it via @include or trim it.
    try out.writer().writeAll("\ninstruction files:\n");
    const instr_warning = instructions_mod.formatLargeInstructionWarning(allocator, runtime.cwd) catch "";
    defer if (instr_warning.len > 0) allocator.free(instr_warning);
    if (instr_warning.len > 0) {
        try out.writer().writeAll(instr_warning);
    } else {
        try out.writer().print("  (all under {d} bytes)\n", .{instructions_mod.MAX_INSTRUCTION_FILE_CHARS});
    }

    try out.writer().writeAll("\nprompt context:\n");
    const prompt_context = runtime.promptContextReport("(doctor diagnostic probe)") catch "";
    defer if (prompt_context.len > 0) allocator.free(prompt_context);
    if (prompt_context.len > 0) {
        try out.writer().writeAll(prompt_context);
        if (!std.mem.endsWith(u8, prompt_context, "\n")) try out.writer().writeByte('\n');
    } else {
        try out.writer().writeAll("  prompt context analysis unavailable\n");
    }

    // Session storage footprint
    try out.writer().writeAll("\nsession storage:\n");
    const sessions_dir = runtime.store.sessions_dir;
    const stats = sessionStorageStats(allocator, sessions_dir) catch SessionStats{};
    var size_buf: [32]u8 = undefined;
    try out.writer().print(
        "  {d} file(s), {s} on disk at {s}\n",
        .{ stats.file_count, format_mod_local.formatFileSize(&size_buf, stats.total_bytes), sessions_dir },
    );
    if (runtime.cfg.session_retention_days == 0) {
        try out.writer().writeAll("  [warn] session_retention_days = 0 -- sessions never expire. Set in ~/.zcode/config.toml to auto-prune.\n");
    } else {
        try out.writer().print("  retention_days = {d}\n", .{runtime.cfg.session_retention_days});
    }

    try out.writer().writeAll("\nAPI / daemon access control:\n");
    try out.writer().print("  api_profile: {s}\n", .{if (runtime.cfg.api_profile.len == 0) "full (default)" else runtime.cfg.api_profile});
    try out.writer().print("  api_role: {s}\n", .{if (runtime.cfg.api_role.len == 0) "(not fixed; token/OIDC may provide role)" else runtime.cfg.api_role});
    try out.writer().print("  api_auth_required: {}\n", .{runtime.cfg.api_auth_required});
    if (runtime.cfg.api_auth_required) {
        if (runtime.cfg.api_bearer_token.len > 0) {
            try out.writer().writeAll("  api_bearer_token: <set>\n");
        } else {
            try out.writer().writeAll("  api_bearer_token: (not set)\n");
        }
        const oidc_ready = runtime.cfg.api_oidc_issuer.len > 0 and
            runtime.cfg.api_oidc_audience.len > 0 and
            (runtime.cfg.api_oidc_hs256_secret.len > 0 or
                runtime.cfg.api_oidc_jwks_json.len > 0 or
                runtime.cfg.api_oidc_jwks_file.len > 0 or
                runtime.cfg.api_oidc_jwks_url.len > 0);
        try out.writer().print("  api_oidc: {s}\n", .{if (oidc_ready) "configured" else "not configured"});
        if (oidc_ready) {
            try out.writer().print("  api_oidc_hs256: {s}\n", .{if (runtime.cfg.api_oidc_hs256_secret.len > 0) "configured" else "not configured"});
            try out.writer().print("  api_oidc_rs256_jwks: {s}\n", .{if (runtime.cfg.api_oidc_jwks_json.len > 0 or runtime.cfg.api_oidc_jwks_file.len > 0 or runtime.cfg.api_oidc_jwks_url.len > 0) "configured" else "not configured"});
        }
    } else {
        try out.writer().writeAll("  [warn] API auth is optional; set api_auth_required = true for managed API hosts.\n");
    }
    if (@import("core/env.zig").getenv("ZCODE_DAEMON_ROLE")) |role| {
        try out.writer().print("  daemon_role: {s}\n", .{role});
    } else {
        try out.writer().writeAll("  daemon_role: owner (default for local bearer-token daemon)\n");
    }

    // Process metrics from the global counters
    try out.writer().writeAll("\nprocess metrics (this session):\n");
    const lines_added = metrics_mod.globalMetrics().getCounter(metrics_mod.Names.lines_added_total);
    const lines_removed = metrics_mod.globalMetrics().getCounter(metrics_mod.Names.lines_removed_total);
    try out.writer().print("  lines added: {d}\n", .{lines_added});
    try out.writer().print("  lines removed: {d}\n", .{lines_removed});
    const api_ms = metrics_mod.globalMetrics().getCounter(metrics_mod.Names.api_duration_ms_total);
    const wall_ms = metrics_mod.getSessionWallDurationMs();
    var dur_buf1: [32]u8 = undefined;
    var dur_buf2: [32]u8 = undefined;
    try out.writer().print("  api duration: {s}\n", .{format_mod_local.formatDuration(&dur_buf1, api_ms)});
    try out.writer().print("  wall duration: {s}\n", .{format_mod_local.formatDuration(&dur_buf2, wall_ms)});

    // Keybinding validation. Surfaces structured warnings produced while
    // loading ~/.zcode/keybindings.json (invalid_context / invalid_action /
    // duplicate / parse_error) plus reserved-conflict counts so users see
    // why a binding they configured was silently ignored. Ported in spirit
    // from claude-code-main validate.ts formatWarnings.
    try out.writer().writeAll("\nkeybindings:\n");
    {
        const keybindings_mod = @import("cli/keybindings.zig");
        var report = keybindings_mod.loadRuntimeKeybindingsReport(allocator);
        defer report.deinit(allocator);
        switch (report.status) {
            .defaults_missing_file => try out.writer().writeAll("  no keybindings.json; using defaults\n"),
            .defaults_parse_error => try out.writer().writeAll("  [warn] keybindings.json failed to parse; using defaults\n"),
            .loaded_file => {
                if (report.warning_count == 0 and report.warnings.items.len == 0) {
                    try out.writer().writeAll("  loaded; no validation issues\n");
                } else {
                    if (report.warning_count > 0) {
                        try out.writer().print(
                            "  [warn] {d} reserved-binding conflict{s} (see log)\n",
                            .{ report.warning_count, if (report.warning_count == 1) "" else "s" },
                        );
                    }
                    for (report.warnings.items) |w| {
                        const tag = switch (w.severity) {
                            .@"error" => "fail",
                            .warning => "warn",
                        };
                        try out.writer().print("  [{s}] {s}: {s}\n", .{ tag, @tagName(w.kind), w.message });
                    }
                }
            },
        }
    }

    // Config files
    try out.writer().writeAll("\nconfig files:\n");
    const path_utils = @import("core/path_utils.zig");
    const home_owned: ?[]u8 = path_utils.getHomeDir(allocator) catch null;
    defer if (home_owned) |h| allocator.free(h);
    const home: []const u8 = home_owned orelse "~";
    const user_cfg = try std.fmt.allocPrint(allocator, "{s}/.zcode/config.toml", .{home});
    defer allocator.free(user_cfg);
    const user_exists = std.Io.Dir.cwd().access(rt.io, user_cfg, .{}) != error.FileNotFound;
    try out.writer().print("[{s}] {s}\n", .{ if (user_exists) "found" else "none", user_cfg });

    // XDG base directories. Ported from claude-code-main/src/
    // utils/xdg.ts (pass 142). Shows where XDG-honouring
    // features store caches, state, and data so enterprise users
    // who set XDG_CACHE_HOME etc. can confirm zcode picked them
    // up instead of silently falling back to ~/.cache.
    try out.writer().writeAll("\nXDG base directories:\n");
    const xdg_mod = @import("core/xdg.zig");
    if (xdg_mod.getCacheHome(allocator)) |cache_path| {
        defer allocator.free(cache_path);
        const cache_src = if (@import("core/env.zig").getenv("XDG_CACHE_HOME")) |_| "XDG_CACHE_HOME" else "default";
        try out.writer().print("  cache:  {s} ({s})\n", .{ cache_path, cache_src });
    } else |_| {
        try out.writer().writeAll("  cache:  (unavailable -- HOME not set)\n");
    }
    if (xdg_mod.getConfigHome(allocator)) |config_path| {
        defer allocator.free(config_path);
        const config_src = if (@import("core/env.zig").getenv("XDG_CONFIG_HOME")) |_| "XDG_CONFIG_HOME" else "default";
        try out.writer().print("  config: {s} ({s})\n", .{ config_path, config_src });
    } else |_| {}
    if (xdg_mod.getDataHome(allocator)) |data_path| {
        defer allocator.free(data_path);
        const data_src = if (@import("core/env.zig").getenv("XDG_DATA_HOME")) |_| "XDG_DATA_HOME" else "default";
        try out.writer().print("  data:   {s} ({s})\n", .{ data_path, data_src });
    } else |_| {}
    if (xdg_mod.getStateHome(allocator)) |state_path| {
        defer allocator.free(state_path);
        const state_src = if (@import("core/env.zig").getenv("XDG_STATE_HOME")) |_| "XDG_STATE_HOME" else "default";
        try out.writer().print("  state:  {s} ({s})\n", .{ state_path, state_src });
    } else |_| {}

    try out.writer().writeAll("\n=== diagnostics complete ===\n");
    return out.toOwnedSlice();
}

const SessionStats = struct {
    file_count: usize = 0,
    total_bytes: u64 = 0,
};

/// Walk `sessions_dir` counting `.jsonl` entries and their sizes so
/// /doctor can show the user how much disk their session history
/// occupies. Returns zeros when the directory is missing or
/// unreadable -- /doctor treats that as "no sessions yet" and the
/// output reads naturally.
fn sessionStorageStats(allocator: std.mem.Allocator, sessions_dir: []const u8) !SessionStats {
    _ = allocator;
    var dir = std.Io.Dir.cwd().openDir(rt.io, sessions_dir, .{ .iterate = true }) catch return .{};
    defer dir.close(rt.io);

    var stats: SessionStats = .{};
    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const stat = dir.statFile(rt.io, entry.name, .{}) catch continue;
        stats.file_count += 1;
        stats.total_bytes += stat.size;
    }
    return stats;
}

fn checkCommand(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const result = std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn renderEnvironmentInfo(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll("environment:\n");
    // Use platform_mod so WSL is reported correctly instead of being
    // misidentified as plain "linux". Matches Claude Code's getPlatform.
    try out.writer().print("  platform: {s}\n", .{platform_mod.detect().toString()});
    try out.writer().print("  arch: {s}\n", .{@tagName(builtin.cpu.arch)});
    try out.writer().print("  shell: {s}\n", .{@import("core/env.zig").getenv("SHELL") orelse "unknown"});
    try out.writer().print("  cwd: {s}\n", .{runtime.cwd});
    try out.writer().print("  provider: {s}\n", .{runtime.active_provider});
    try out.writer().print("  model: {s}\n", .{runtime.active_model});
    try out.writer().print("  version: {s}\n", .{build_options.app_version});
    try out.writer().print("  approval_mode: {s}\n", .{runtime.cfg.approval_mode});
    try out.writer().print("  sandbox: {s}\n", .{runtime.cfg.sandbox});
    try out.writer().print("  streaming: {}\n", .{runtime.cfg.interactive_streaming});
    try out.writer().print("  context_window: {d}\n", .{runtime.cfg.model_context_window});

    return out.toOwnedSlice();
}

const copyToClipboard = @import("core/clipboard.zig").copyText;

// --- Model catalog helpers ---

const ModelCatalogItem = struct {
    id: []u8,
    context_window: usize,
};

fn freeModelCatalog(allocator: std.mem.Allocator, items: []ModelCatalogItem) void {
    for (items) |item| allocator.free(item.id);
    allocator.free(items);
}

/// Resolve the context window for `model`, layering the `[1m]` long-context
/// suffix over the catalog (reference getContextWindowForModel,
/// utils/context.ts:51-98). The `[1m]` suffix wins over the catalog/hardcoded
/// default and yields 1,000,000 tokens; it honors the
/// CLAUDE_CODE_DISABLE_1M_CONTEXT switch via model_alias.has1mContext. Otherwise
/// the catalog entry's context_window is used; if the model is absent from the
/// catalog (or its entry is 0) the current window is preserved.
fn resolveContextWindowForModel(model: []const u8, catalog: []const ModelCatalogItem, current_window: usize) usize {
    if (model_alias.has1mContext(model)) return 1_000_000;
    for (catalog) |entry| {
        if (std.mem.eql(u8, entry.id, model)) {
            if (entry.context_window > 0) return entry.context_window;
            return current_window;
        }
    }
    // Model not found in catalog -- keep existing context_window.
    return current_window;
}

/// After a model switch, look up the new model's context_window from
/// the catalog and update cfg.model_context_window. This ensures
/// budget/compaction uses the correct size for the active model.
fn updateContextWindowForModel(_: std.mem.Allocator, runtime: *AgentRuntime, catalog: []const ModelCatalogItem) void {
    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    mutable_cfg.model_context_window = resolveContextWindowForModel(
        runtime.active_model,
        catalog,
        mutable_cfg.model_context_window,
    );
}

fn appendCatalogModel(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(ModelCatalogItem),
    model_id_raw: []const u8,
    context_window: usize,
) !void {
    const model_id = std.mem.trim(u8, model_id_raw, " \t\r\n");
    if (model_id.len == 0) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing.id, model_id)) return;
    }
    try list.ensureUnusedCapacity(1);
    const dup_id = try allocator.dupe(u8, model_id);
    list.appendAssumeCapacity(.{
        .id = dup_id,
        .context_window = context_window,
    });
}

fn trimQuotes(raw: []const u8) []const u8 {
    if (raw.len < 2) return raw;
    if ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\'')) {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

pub fn isKnownProviderName(name: []const u8) bool {
    return std.mem.eql(u8, name, "openai") or
        std.mem.eql(u8, name, "openai-compatible") or
        std.mem.eql(u8, name, "deepseek") or
        std.mem.eql(u8, name, "anthropic") or
        std.mem.eql(u8, name, "gemini") or
        std.mem.eql(u8, name, "local") or
        std.mem.eql(u8, name, "ollama") or
        std.mem.eql(u8, name, "groq") or
        std.mem.eql(u8, name, "openrouter") or
        std.mem.eql(u8, name, "azure") or
        std.mem.eql(u8, name, "azure-openai") or
        std.mem.eql(u8, name, "mock");
}

pub fn configuredModelTokenExists(raw_models: []const u8, token: []const u8) bool {
    var body = std.mem.trim(u8, raw_models, " \t\r\n");
    if (body.len == 0) return false;
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') {
        body = body[1 .. body.len - 1];
    }

    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part_raw| {
        var configured = trimQuotes(std.mem.trim(u8, part_raw, " \t\r\n"));
        if (configured.len == 0) continue;
        if (std.mem.lastIndexOfScalar(u8, configured, ':')) |idx| {
            const maybe_ctx = std.mem.trim(u8, configured[idx + 1 ..], " \t");
            if (maybe_ctx.len > 0) {
                if (std.fmt.parseInt(usize, maybe_ctx, 10)) |_| {
                    configured = configured[0..idx];
                } else |_| {}
            }
        }
        if (std.mem.eql(u8, configured, token)) return true;
    }
    return false;
}

fn appendConfiguredCatalogFromString(
    allocator: std.mem.Allocator,
    list: *std.array_list.Managed(ModelCatalogItem),
    raw_models: []const u8,
    default_context: usize,
) !void {
    var body = std.mem.trim(u8, raw_models, " \t\r\n");
    if (body.len == 0) return;
    if (body.len >= 2 and body[0] == '[' and body[body.len - 1] == ']') {
        body = body[1 .. body.len - 1];
    }

    var parts = std.mem.splitScalar(u8, body, ',');
    while (parts.next()) |part_raw| {
        var token = trimQuotes(std.mem.trim(u8, part_raw, " \t\r\n"));
        if (token.len == 0) continue;

        var model_id = token;
        var context_window = default_context;
        if (std.mem.lastIndexOfScalar(u8, token, ':')) |idx| {
            const maybe_id = std.mem.trim(u8, token[0..idx], " \t");
            const maybe_ctx = std.mem.trim(u8, token[idx + 1 ..], " \t");
            if (maybe_id.len > 0 and maybe_ctx.len > 0) {
                context_window = std.fmt.parseInt(usize, maybe_ctx, 10) catch default_context;
                model_id = maybe_id;
            }
        }

        try appendCatalogModel(allocator, list, model_id, context_window);
    }
}

fn appendConfiguredCatalogModels(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider_name: []const u8,
    active_model: []const u8,
    list: *std.array_list.Managed(ModelCatalogItem),
) !void {
    const ctx = cfg.model_context_window;

    try appendCatalogModel(allocator, list, active_model, ctx);
    try appendConfiguredCatalogFromString(allocator, list, cfg.available_models, ctx);

    if (std.mem.eql(u8, cfg.default_provider, provider_name)) {
        try appendCatalogModel(allocator, list, cfg.default_model, ctx);
    }
    if (cfg.fallback_model.len > 0 and std.mem.eql(u8, cfg.fallback_provider, provider_name)) {
        try appendCatalogModel(allocator, list, cfg.fallback_model, ctx);
    }
    if (cfg.preprocessor_enabled and cfg.preprocessor_model.len > 0 and std.mem.eql(u8, cfg.preprocessor_provider, provider_name)) {
        try appendCatalogModel(allocator, list, cfg.preprocessor_model, ctx);
    }
}

fn modelSliceContainsId(models: []const types.ModelInfo, model_id: []const u8) bool {
    for (models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return true;
    }
    return false;
}

fn staticPlaceholderIds(provider_name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, provider_name, "openai") or std.mem.eql(u8, provider_name, "openai-compatible")) {
        return &.{ "gpt-4.1", "gpt-4.1-mini" };
    }
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return &.{ "claude-sonnet-4-5", "claude-opus-4-1" };
    }
    if (std.mem.eql(u8, provider_name, "gemini")) {
        return &.{ "gemini-2.5-pro", "gemini-2.5-flash" };
    }
    if (std.mem.eql(u8, provider_name, "deepseek")) {
        return &.{ "deepseek-chat", "deepseek-reasoner" };
    }
    if (std.mem.eql(u8, provider_name, "local") or std.mem.eql(u8, provider_name, "ollama")) {
        return &.{ "qwen2.5-coder", "llama3.1" };
    }
    if (std.mem.eql(u8, provider_name, "openrouter")) {
        return &.{ "anthropic/claude-sonnet-4", "openai/gpt-4.1" };
    }
    if (std.mem.eql(u8, provider_name, "groq")) {
        return &.{ "llama-3.3-70b-versatile", "llama-3.1-8b-instant", "gemma2-9b-it" };
    }
    if (std.mem.eql(u8, provider_name, "azure") or std.mem.eql(u8, provider_name, "azure-openai")) {
        return &.{ "gpt-4.1", "gpt-4o" };
    }
    return &.{};
}

fn looksLikeStaticPlaceholderCatalog(provider_name: []const u8, models: []const types.ModelInfo) bool {
    const expected = staticPlaceholderIds(provider_name);
    if (expected.len == 0) return false;
    if (models.len != expected.len) return false;
    for (expected) |id| {
        if (!modelSliceContainsId(models, id)) return false;
    }
    return true;
}

pub fn resolveModelCatalogForProvider(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    provider_name: []const u8,
    active_model: []const u8,
) ![]ModelCatalogItem {
    var catalog = std.array_list.Managed(ModelCatalogItem).init(allocator);
    errdefer {
        for (catalog.items) |item| allocator.free(item.id);
        catalog.deinit();
    }

    try appendConfiguredCatalogModels(allocator, cfg, provider_name, active_model, &catalog);
    const has_configured_models = catalog.items.len > 0;

    if (providers.createAdapterWithOverrides(allocator, provider_name, agent_runtime.providerAdapterOverrides(cfg, provider_name, false))) |created_adapter| {
        var adapter = created_adapter;
        defer adapter.deinit(allocator);
        if (providers.listModelsCached(allocator, &adapter, provider_name)) |discovered| {
            defer providers.freeModelInfos(allocator, discovered);
            const ignore_placeholders = has_configured_models and looksLikeStaticPlaceholderCatalog(provider_name, discovered);
            if (!ignore_placeholders) {
                for (discovered) |model| {
                    try appendCatalogModel(allocator, &catalog, model.id, model.context_window);
                }
            }
        } else |_| {}
    } else |_| {}

    // Include models from fallback provider (e.g. OpenRouter when default is Moonshot).
    if (cfg.fallback_provider.len > 0 and !std.mem.eql(u8, cfg.fallback_provider, provider_name)) {
        try appendCrossProviderModels(allocator, cfg, cfg.fallback_provider, true, &catalog);
    }

    // Include models from local/ollama provider if not already the active provider.
    if (!std.mem.eql(u8, provider_name, "local") and !std.mem.eql(u8, provider_name, "ollama") and cfg.local_base_url.len > 0) {
        try appendCrossProviderModels(allocator, cfg, "local", false, &catalog);
    }

    if (catalog.items.len == 0) {
        try appendCatalogModel(allocator, &catalog, active_model, cfg.model_context_window);
    }

    return catalog.toOwnedSlice();
}

fn appendCrossProviderModels(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    cross_provider: []const u8,
    is_fallback: bool,
    catalog: *std.array_list.Managed(ModelCatalogItem),
) !void {
    var adapter = providers.createAdapterWithOverrides(
        allocator,
        cross_provider,
        agent_runtime.providerAdapterOverrides(cfg, cross_provider, is_fallback),
    ) catch return;
    defer adapter.deinit(allocator);

    const discovered = providers.listModelsCached(allocator, &adapter, cross_provider) catch return;
    defer providers.freeModelInfos(allocator, discovered);

    for (discovered) |model| {
        // Prefix with provider name so /model local/qwen3:32b works.
        const prefixed = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cross_provider, model.id }) catch continue;
        errdefer allocator.free(prefixed);

        // Skip duplicates.
        var already = false;
        for (catalog.items) |existing| {
            if (std.mem.eql(u8, existing.id, prefixed)) {
                already = true;
                break;
            }
        }
        if (already) {
            allocator.free(prefixed);
            continue;
        }

        catalog.ensureUnusedCapacity(1) catch {
            allocator.free(prefixed);
            return error.OutOfMemory;
        };
        catalog.appendAssumeCapacity(.{
            .id = prefixed,
            .context_window = model.context_window,
        });
    }
}

fn renderReplModels(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const models = try resolveModelCatalogForProvider(
        allocator,
        runtime.cfg,
        runtime.active_provider,
        runtime.active_model,
    );
    defer freeModelCatalog(allocator, models);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print("active provider/model: {s}/{s}\n", .{ runtime.active_provider, runtime.active_model });
    try out.writer().writeAll("available models:\n");

    for (models) |model| {
        const marker = if (std.mem.eql(u8, model.id, runtime.active_model)) "*" else " ";
        try out.writer().print("{s} {s}\tctx={d}\n", .{ marker, model.id, model.context_window });
        // Annotate deprecated models inline so the listing flags retirement.
        var dep_buf: [256]u8 = undefined;
        if (deprecation.getModelDeprecationWarning(&dep_buf, model.id, runtime.active_provider)) |warning| {
            try out.writer().print("    {s}\n", .{warning});
        }
    }
    if (models.len == 0) {
        try out.writer().writeAll("no models\n");
    }
    try out.writer().writeAll("\nuse /model <id|provider/id> to switch model for this session\n");
    return out.toOwnedSlice();
}

fn renderReplModelPickerData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const models = try resolveModelCatalogForProvider(
        allocator,
        runtime.cfg,
        runtime.active_provider,
        runtime.active_model,
    );
    defer freeModelCatalog(allocator, models);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print("active_provider={s}\n", .{runtime.active_provider});
    try out.writer().print("active_model={s}\n", .{runtime.active_model});
    for (models) |model| {
        try out.writer().print("item={s}\t{d}\n", .{ model.id, model.context_window });
    }

    return out.toOwnedSlice();
}

fn renderTasksOverlayData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const TaskOverlayItem = struct {
        id: []const u8,
        title: []const u8,
        status: []const u8,
        summary: []const u8,
        command: []const u8,
        owner: []const u8,
        priority: []const u8,
        detail: []const u8,
        progress: u8,
        run_pid: i64,
        updated_ts: i64,
    };
    const Payload = struct {
        initial_selection: usize,
        items: []const TaskOverlayItem,
    };

    const snapshots = try task_mod.listTaskSnapshots(allocator, runtime.cwd, null);
    defer task_mod.freeTaskSnapshots(allocator, snapshots);

    const items = try allocator.alloc(TaskOverlayItem, snapshots.len);
    defer {
        for (items) |item| allocator.free(item.detail);
        allocator.free(items);
    }

    for (snapshots, 0..) |snapshot, idx| {
        const detail = try task_mod.taskOutput(allocator, runtime.cwd, snapshot.id, null);
        items[idx] = .{
            .id = snapshot.id,
            .title = snapshot.title,
            .status = snapshot.status,
            .summary = snapshot.summary,
            .command = snapshot.command,
            .owner = snapshot.owner,
            .priority = snapshot.priority,
            .detail = detail,
            .progress = snapshot.progress,
            .run_pid = snapshot.run_pid,
            .updated_ts = snapshot.updated_ts,
        };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(Payload{
        .initial_selection = 0,
        .items = items,
    }, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn formatSessionUpdatedSummary(out: []u8, updated_ts: i64, now_ts: i64) []const u8 {
    if (updated_ts <= 0) return "updated time unknown";
    const delta = if (now_ts > updated_ts) now_ts - updated_ts else 0;
    if (delta < 60) return std.fmt.bufPrint(out, "updated {d}s ago", .{delta}) catch "updated recently";
    if (delta < 60 * 60) return std.fmt.bufPrint(out, "updated {d}m ago", .{@divFloor(delta, 60)}) catch "updated recently";
    if (delta < 60 * 60 * 24) return std.fmt.bufPrint(out, "updated {d}h ago", .{@divFloor(delta, 60 * 60)}) catch "updated recently";
    return std.fmt.bufPrint(out, "updated {d}d ago", .{@divFloor(delta, 60 * 60 * 24)}) catch "updated recently";
}

fn renderSessionsOverlayData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const SessionOverlayItem = struct {
        id: []const u8,
        label: []const u8,
        updated_summary: []const u8,
        is_current: bool,
        // Phase 11 sessions-07: branch + first-prompt breadcrumbs surfaced for
        // display in the picker. Always owned (empty string when absent) so the
        // cleanup loop frees them uniformly.
        branch: []const u8,
        first_prompt: []const u8,
    };
    const Payload = struct {
        initial_selection: usize,
        items: []const SessionOverlayItem,
    };

    const entries = try runtime.store.list();
    defer runtime.store.freeSessionEntries(entries);

    const items = try allocator.alloc(SessionOverlayItem, entries.len);
    defer {
        for (items) |item| {
            allocator.free(item.updated_summary);
            allocator.free(item.label);
            allocator.free(item.branch);
            allocator.free(item.first_prompt);
        }
        allocator.free(items);
    }

    const now_ts = clock.nowSeconds();
    var current_index: usize = 0;
    for (entries, 0..) |entry, idx| {
        var updated_buf: [96]u8 = undefined;
        const updated_summary = formatSessionUpdatedSummary(&updated_buf, entry.updated_ts, now_ts);
        // Title precedence (Phase 11 sessions-06): user label, else AI title,
        // else id. currentTitle always allocates, so item.label is owned and
        // freed in the cleanup loop above.
        const title = runtime.store.currentTitle(entry.id) catch try allocator.dupe(u8, entry.id);
        errdefer allocator.free(title);
        const updated_owned = try allocator.dupe(u8, updated_summary);
        errdefer allocator.free(updated_owned);
        // Phase 11 sessions-07: best-effort branch + first-prompt breadcrumbs.
        // Normalize a missing sidecar to an owned empty string so the JSON
        // payload always carries the field and the cleanup loop is uniform.
        const branch_opt = runtime.store.readBranch(entry.id) catch null;
        const branch_owned = branch_opt orelse try allocator.dupe(u8, "");
        errdefer allocator.free(branch_owned);
        const fp_opt = runtime.store.readFirstPrompt(entry.id) catch null;
        const fp_owned = fp_opt orelse try allocator.dupe(u8, "");
        errdefer allocator.free(fp_owned);
        items[idx] = .{
            .id = entry.id,
            .label = title,
            .updated_summary = updated_owned,
            .is_current = std.mem.eql(u8, entry.id, runtime.session_id),
            .branch = branch_owned,
            .first_prompt = fp_owned,
        };
        if (items[idx].is_current) current_index = idx;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(Payload{
        .initial_selection = current_index,
        .items = items,
    }, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

/// One member row rendered in the teams overlay (swarm-tasks-06). Carries the
/// structured per-member fields the JSON team file now stores so the overlay
/// can show a row per teammate instead of one opaque `members=` blob.
const TeamMemberRow = struct {
    name: []u8,
    agent_type: []u8,
    model: []u8,
    cwd: []u8,

    fn deinit(self: *TeamMemberRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.agent_type);
        allocator.free(self.model);
        allocator.free(self.cwd);
    }
};

const TeamOverlayItem = struct {
    name: []u8,
    /// Comma-joined member-name summary, kept for the legacy prompt-suggestion
    /// consumers that render a one-line description. Empty when no members.
    members: []u8,
    member_rows: []TeamMemberRow,
    last_message: []u8,
    created_ts: i64,
    message_count: usize,

    fn deinit(self: *TeamOverlayItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.members);
        for (self.member_rows) |*row| row.deinit(allocator);
        allocator.free(self.member_rows);
        allocator.free(self.last_message);
    }
};

/// Parse a `.team` file into the fields the repl surfaces. Routes through the
/// team module's structured JSON reader (swarm-tasks-06) and falls back to the
/// legacy `key=value` reader for old files. `members` is a comma-joined summary
/// of member names (empty when none); `member_rows` carries the structured
/// per-member fields for the overlay. The caller owns every returned slice.
fn parseTeamMetadata(allocator: std.mem.Allocator, file_data: []const u8, fallback_name: []const u8) !struct {
    name: []u8,
    members: []u8,
    member_rows: []TeamMemberRow,
    created_ts: i64,
} {
    var team_file = try team_tool.parseTeamFileBytes(allocator, file_data, fallback_name);
    defer team_file.deinit(allocator);

    const name = try allocator.dupe(u8, team_file.name);
    errdefer allocator.free(name);

    var rows = std.array_list.Managed(TeamMemberRow).init(allocator);
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit();
    }
    var summary = std_io.StringBuilder.init(allocator);
    errdefer summary.deinit();
    for (team_file.members, 0..) |member, idx| {
        if (idx != 0) try summary.appendSlice(", ");
        try summary.appendSlice(member.name);
        try rows.append(.{
            .name = try allocator.dupe(u8, member.name),
            .agent_type = try allocator.dupe(u8, member.agent_type),
            .model = try allocator.dupe(u8, member.model),
            .cwd = try allocator.dupe(u8, member.cwd),
        });
    }

    return .{
        .name = name,
        .members = try summary.toOwnedSlice(),
        .member_rows = try rows.toOwnedSlice(),
        .created_ts = team_file.created_ts,
    };
}

fn readTeamMessageSummary(allocator: std.mem.Allocator, cwd: []const u8, team_name: []const u8) !struct {
    message_count: usize,
    last_message: []u8,
} {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.log", .{team_name});
    defer allocator.free(file_name);
    const rel = try std.fs.path.join(allocator, &.{ tool_helpers.MESSAGES_SUBPATH, file_name });
    defer allocator.free(rel);
    const path = try tool_helpers.workspacePathAlloc(allocator, cwd, rel);
    defer allocator.free(path);

    const file_data = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .message_count = 0,
            .last_message = try allocator.dupe(u8, ""),
        },
        else => return err,
    };
    defer allocator.free(file_data);

    var message_count: usize = 0;
    var last_line: []const u8 = "";
    var lines = std.mem.splitScalar(u8, file_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        message_count += 1;
        last_line = line;
    }

    return .{
        .message_count = message_count,
        .last_message = try allocator.dupe(u8, last_line),
    };
}

fn teamItemLessThan(_: void, lhs: TeamOverlayItem, rhs: TeamOverlayItem) bool {
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn renderTeamsOverlayData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const teams_dir_path = try tool_helpers.workspacePathAlloc(allocator, runtime.cwd, tool_helpers.TEAMS_SUBPATH);
    defer allocator.free(teams_dir_path);

    var dir = std.Io.Dir.cwd().openDir(rt.io, teams_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "no local teams yet\ncreate teams through the local team tools to populate this view"),
        else => return err,
    };
    defer dir.close(rt.io);

    var items = std.array_list.Managed(TeamOverlayItem).init(allocator);
    defer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".team")) continue;

        const team_path = try std.fs.path.join(allocator, &.{ teams_dir_path, entry.name });
        defer allocator.free(team_path);
        const file_data = try std.Io.Dir.cwd().readFileAlloc(rt.io, team_path, allocator, .limited(16 * 1024));
        defer allocator.free(file_data);

        const fallback_name = entry.name[0 .. entry.name.len - ".team".len];
        const meta = try parseTeamMetadata(allocator, file_data, fallback_name);
        errdefer {
            allocator.free(meta.name);
            allocator.free(meta.members);
            for (meta.member_rows) |*row| row.deinit(allocator);
            allocator.free(meta.member_rows);
        }
        const message_summary = try readTeamMessageSummary(allocator, runtime.cwd, meta.name);

        try items.append(.{
            .name = meta.name,
            .members = meta.members,
            .member_rows = meta.member_rows,
            .last_message = message_summary.last_message,
            .created_ts = meta.created_ts,
            .message_count = message_summary.message_count,
        });
    }

    if (items.items.len == 0) {
        return allocator.dupe(u8, "no local teams yet\ncreate teams through the local team tools to populate this view");
    }

    std.mem.sort(TeamOverlayItem, items.items, {}, teamItemLessThan);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("local teams: {d}\nworkspace: {s}\n\n", .{ items.items.len, runtime.cwd });
    for (items.items) |item| {
        try out.writer().print("{s}\n", .{item.name});
        if (item.member_rows.len == 0) {
            try out.writer().writeAll("  members: (none recorded)\n");
        } else {
            try out.writer().print("  members: {d}\n", .{item.member_rows.len});
            for (item.member_rows) |row| {
                try out.writer().print("    - {s}", .{row.name});
                if (row.agent_type.len > 0) try out.writer().print(" ({s})", .{row.agent_type});
                if (row.model.len > 0) try out.writer().print(" model={s}", .{row.model});
                if (row.cwd.len > 0) try out.writer().print(" cwd={s}", .{row.cwd});
                try out.writer().writeByte('\n');
            }
        }
        try out.writer().print("  messages: {d}\n", .{item.message_count});
        if (item.created_ts > 0) {
            try out.writer().print("  created_ts: {d}\n", .{item.created_ts});
        }
        if (item.last_message.len > 0) {
            try out.writer().print("  last: {s}\n", .{item.last_message});
        }
        try out.writer().writeByte('\n');
    }
    return out.toOwnedSlice();
}

fn renderBridgeOverlayData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().writeAll("bridge status\n\n");
    try out.writer().print("browser_bridge_enabled: {}\n", .{runtime.cfg.browser_bridge_enabled});
    try out.writer().print("browser_bridge_port: {d}\n", .{runtime.cfg.browser_bridge_port});

    if (runtime.browser) |bridge| {
        const connected = bridge.isConnected();
        try out.writer().print("browser_connected: {}\n", .{connected});
        if (connected) {
            const tools = bridge.listTools() catch try allocator.alloc(mcp_client.ToolInfo, 0);
            defer mcp_client.freeToolInfos(allocator, tools);
            try out.writer().print("browser_tools: {d}\n", .{tools.len});
        }
    } else {
        try out.writer().writeAll("browser_connected: false\n");
        try out.writer().writeAll("browser_runtime: not started\n");
    }

    try out.writer().print("mcp_tool_bridge_enabled: {}\n", .{runtime.cfg.mcp_tool_bridge_enabled});
    try out.writer().print("session_auto_mode: {}\n", .{runtime.yolo_mode});
    try out.writer().print("session_auto_approve_high: {}\n", .{runtime.auto_approve_high});
    try out.writer().print("approval_mode: {s}\n", .{runtime.cfg.approval_mode});
    try out.writer().print("sandbox: {s}\n", .{runtime.cfg.sandbox});
    try out.writer().print("cwd: {s}\n", .{runtime.cwd});

    return out.toOwnedSlice();
}

fn isManagedBackgroundTaskActive(status: []const u8) bool {
    return std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "queued");
}

fn renderTasksFooterState(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const snapshots = try task_mod.listTaskSnapshots(allocator, runtime.cwd, null);
    defer task_mod.freeTaskSnapshots(allocator, snapshots);

    var active: usize = 0;
    for (snapshots) |snapshot| {
        if (isManagedBackgroundTaskActive(snapshot.status)) active += 1;
    }

    if (snapshots.len == 0) return allocator.dupe(u8, "idle");
    if (active == 0) {
        return std.fmt.allocPrint(allocator, "{d} total", .{snapshots.len});
    }
    return std.fmt.allocPrint(allocator, "{d} active", .{active});
}

fn renderTeamsFooterState(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const teams_dir_path = try tool_helpers.workspacePathAlloc(allocator, runtime.cwd, tool_helpers.TEAMS_SUBPATH);
    defer allocator.free(teams_dir_path);

    var dir = std.Io.Dir.cwd().openDir(rt.io, teams_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "none"),
        else => return err,
    };
    defer dir.close(rt.io);

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".team")) count += 1;
    }

    if (count == 0) return allocator.dupe(u8, "none");
    return std.fmt.allocPrint(allocator, "{d} teams", .{count});
}

fn renderBridgeFooterState(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    if (runtime.browser) |bridge| {
        if (bridge.isConnected()) return allocator.dupe(u8, "live");
    }
    if (runtime.cfg.browser_bridge_enabled) {
        return std.fmt.allocPrint(allocator, "port {d}", .{runtime.cfg.browser_bridge_port});
    }
    if (runtime.cfg.mcp_tool_bridge_enabled) return allocator.dupe(u8, "mcp");
    return allocator.dupe(u8, "off");
}

fn renderActiveAgentFooterState(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    if (runtime.activeAgentName()) |name| {
        return std.fmt.allocPrint(allocator, "agent:{s}", .{name});
    }
    return allocator.alloc(u8, 0);
}

fn renderTmuxFooterState(allocator: std.mem.Allocator) ![]u8 {
    const tmux = @import("core/env.zig").getOwned(allocator, "TMUX") catch return allocator.alloc(u8, 0);
    defer allocator.free(tmux);

    const pane = @import("core/env.zig").getOwned(allocator, "TMUX_PANE") catch null;
    defer if (pane) |value| allocator.free(value);
    if (pane) |value| {
        return std.fmt.allocPrint(allocator, "tmux {s}", .{value});
    }
    return allocator.dupe(u8, "tmux");
}

fn renderWorktreeFooterState(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const raw = try runGitCommand(allocator, runtime.cwd, &.{ "git", "worktree", "list", "--porcelain" });
    defer allocator.free(raw);

    var count: usize = 0;
    var matched: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (!std.mem.startsWith(u8, line, "worktree ")) continue;
        count += 1;
        const worktree_path = line["worktree ".len..];
        if (std.mem.eql(u8, std.mem.trimEnd(u8, runtime.cwd, "/"), std.mem.trimEnd(u8, worktree_path, "/"))) {
            matched = worktree_path;
        }
    }

    if (count <= 1) return allocator.alloc(u8, 0);
    const path = matched orelse runtime.cwd;
    return std.fmt.allocPrint(allocator, "worktree:{s}", .{std.fs.path.basename(path)});
}

/// Walk `$PATH` and emit one suggestion per executable found, using
/// the existing DynamicCommandSuggestion tab-separated format. Lets
/// the inline prompt overlay surface shell commands alongside slash
/// commands / @-files / agents. Cached by the REPL for the duration
/// of the session; refresh happens on the same cadence as the other
/// dynamic suggestions.
///
/// Output format per line: "command\t<bin>\t<bin>\t<dir>".
/// Capped at ~4096 entries total so a very long PATH doesn't blow the
/// cache. Duplicates across directories keep only the first hit.
fn renderPromptSuggestionShellBins(allocator: std.mem.Allocator) ![]u8 {
    const PATH = @import("core/env.zig").getenv("PATH") orelse return allocator.alloc(u8, 0);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    const MAX_ENTRIES: usize = 4096;
    var entries: usize = 0;

    var dir_iter = std.mem.tokenizeScalar(u8, PATH, ':');
    while (dir_iter.next()) |dir_path| {
        if (dir_path.len == 0) continue;
        if (entries >= MAX_ENTRIES) break;

        var dir = std.Io.Dir.openDirAbsolute(rt.io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(rt.io);

        var iter = dir.iterate();
        while (iter.next(rt.io) catch null) |entry| {
            if (entries >= MAX_ENTRIES) break;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            // Skip hidden files.
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            // Skip already-seen names (first PATH entry wins, matching
            // shell lookup semantics).
            if (seen.contains(entry.name)) continue;

            // Best-effort executable check via statFile. File systems
            // without a usable mode field (Windows) will fall back to
            // just listing everything, which is fine for suggestions.
            const stat = dir.statFile(rt.io, entry.name, .{}) catch continue;
            _ = stat;

            const owned_name = allocator.dupe(u8, entry.name) catch continue;
            seen.put(owned_name, {}) catch {
                allocator.free(owned_name);
                continue;
            };

            out.writer().print("command\t{s}\t{s}\t{s}\n", .{ entry.name, entry.name, dir_path }) catch continue;
            entries += 1;
        }
    }

    return out.toOwnedSlice();
}

/// Context-aware shell completion for the prompt footer (bash-shell-06).
/// Classifies the word under the (end-of-line) cursor as command / file /
/// variable and shells out to the user's shell (`compgen` for bash, native
/// builtins for zsh) with a 1s timeout and a 15-suggestion cap. On any failure
/// or when the live completion produces nothing, falls back to the PATH-scan
/// command list so the footer is never empty for command completion.
///
/// Output is the same TSV the footer consumes:
///   "<kind>\t<command>\t<label>\t<detail>\n"
fn renderPromptSuggestionShellCompletions(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    // We do not thread the live cursor through the footer callback yet; the
    // prefix is the word ending at the end of the submitted line, which is
    // what the user is actively typing.
    const completions = shell_completion.getShellCompletions(allocator, line, line.len) catch null;
    if (completions) |list| {
        defer shell_completion.freeCompletions(allocator, list);
        const ctx = shell_completion.parseInputContext(line, line.len);
        const kind_label: []const u8 = switch (ctx.kind) {
            .command => "command",
            .file => "file",
            .variable => "variable",
        };

        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        for (list) |suggestion| {
            out.writer().print("{s}\t{s}\t{s}\t{s}\n", .{ kind_label, suggestion, suggestion, kind_label }) catch continue;
        }
        return out.toOwnedSlice();
    }

    // Fall back to the PATH-scan command list (the prior behavior).
    return renderPromptSuggestionShellBins(allocator);
}

fn renderPromptSuggestionAgents(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const agents = try agents_mod.list(allocator, runtime.cwd);
    defer agents_mod.freeList(allocator, agents);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    for (agents) |agent| {
        // Do not advertise an agent type denied by a permission rule
        // (permissions-15, offer-path filter / defense in depth).
        if (runtime.permission_rules.isAgentDenied(runtime.cwd, agent.name)) continue;
        const command = try std.fmt.allocPrint(allocator, "/agent {s}", .{agent.name});
        defer allocator.free(command);
        const label = try std.fmt.allocPrint(allocator, "agent:{s}", .{agent.name});
        defer allocator.free(label);
        try out.writer().print("agent\t{s}\t{s}\t{s}\n", .{ command, label, agent.description });
    }
    return out.toOwnedSlice();
}

/// Build the single-line argument hint shown in gray after a command/skill in
/// the typeahead. Priority (mirrors commandSuggestions.ts createCommandSuggestionItem):
///   1. explicit `argument-hint` frontmatter (e.g. `<pr-url>`),
///   2. else `[arg1] [arg2]` synthesized from named `arguments` via
///      argument_substitution.generateProgressiveArgumentHint (no args typed yet),
///   3. else empty (no hint).
/// The returned slice is owned by the caller (may be a freshly-allocated empty
/// slice). It is always single-line: any tab/newline in the explicit hint is
/// truncated at the first occurrence so the 4-field TSV contract is preserved.
fn suggestionArgumentHint(
    allocator: std.mem.Allocator,
    argument_hint: []const u8,
    arg_names: []const []const u8,
) ![]u8 {
    // 1. Explicit argument-hint frontmatter wins.
    if (argument_hint.len > 0) {
        var hint = argument_hint;
        if (std.mem.indexOfAny(u8, hint, "\n\t\r")) |i| hint = hint[0..i];
        return allocator.dupe(u8, hint);
    }
    // 2. Synthesize `[arg1] [arg2]` from the named argument slots when no
    //    explicit hint is present. generateProgressiveArgumentHint returns null
    //    when there are no remaining slots (e.g. arg_names is empty).
    if (try arg_sub.generateProgressiveArgumentHint(allocator, arg_names, &.{})) |synth| {
        // The synthesized form never contains a tab/newline (names are space-list
        // tokens), so it is TSV-safe as-is.
        return synth;
    }
    // 3. Nothing.
    return allocator.alloc(u8, 0);
}

/// Emit autocomplete suggestion rows for user-authored custom commands
/// (`.zcode/commands/*.md`). Modeled on renderPromptSuggestionSkills: one TSV
/// row per user-invocable command, `command\t/<name>\tcommand:<name>\t<desc>`.
/// The `command` kind token maps to the `.command` SuggestionSource by default
/// in DynamicCommandSuggestionCache.appendFromCommand. The suggestion text is
/// `/<name>` so a namespaced command `frontend:build` becomes `/frontend:build`.
///
/// Extracted as a pure (allocator, cwd) core so the TSV emission is unit-testable
/// without a full runtime; the runtime wrapper below just forwards `runtime.cwd`.
fn renderPromptSuggestionCommandsCore(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const commands = commands_mod.list(allocator, cwd) catch return allocator.alloc(u8, 0);
    defer commands_mod.freeList(allocator, commands);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    for (commands) |command| {
        if (!command.user_invocable) continue;
        const text = try std.fmt.allocPrint(allocator, "/{s}", .{command.name});
        defer allocator.free(text);
        const label = try std.fmt.allocPrint(allocator, "command:{s}", .{command.name});
        defer allocator.free(label);

        // First line only: descriptions can be multi-line (frontmatter
        // `description: |` blocks); a newline/tab would corrupt the TSV the
        // suggestion cache parses on a 4-field, tab-separated contract.
        var desc = command.description;
        if (std.mem.indexOfAny(u8, desc, "\n\t\r")) |i| desc = desc[0..i];

        // Fold the argument hint into the secondary description so the typeahead
        // shows it after the command name (the existing footer renders
        // `secondary` as the gray label). Hint priority: explicit argument-hint
        // frontmatter, else `[arg1] [arg2]` synthesized from named arguments.
        // Always single-line so the 4-field TSV contract holds.
        const hint = try suggestionArgumentHint(allocator, command.argument_hint, command.arg_names);
        defer allocator.free(hint);

        if (hint.len > 0 and desc.len > 0) {
            try out.writer().print("command\t{s}\t{s}\t{s} {s}\n", .{ text, label, desc, hint });
        } else if (hint.len > 0) {
            try out.writer().print("command\t{s}\t{s}\t{s}\n", .{ text, label, hint });
        } else {
            try out.writer().print("command\t{s}\t{s}\t{s}\n", .{ text, label, desc });
        }
    }
    return out.toOwnedSlice();
}

fn renderPromptSuggestionCommands(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    return renderPromptSuggestionCommandsCore(allocator, runtime.cwd);
}

fn renderPromptSuggestionSkills(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const skills = skills_mod.list(allocator, runtime.cwd) catch return allocator.alloc(u8, 0);
    defer skills_mod.freeList(allocator, skills);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    for (skills) |skill| {
        if (!skill.user_invocable) continue;
        const command = try std.fmt.allocPrint(allocator, "/skill {s}", .{skill.name});
        defer allocator.free(command);
        const label = try std.fmt.allocPrint(allocator, "skill:{s}", .{skill.name});
        defer allocator.free(label);
        // First line only: skill descriptions can be multi-line (frontmatter
        // `description: |` blocks); a newline/tab would corrupt the TSV the
        // suggestion cache parses.
        var desc = skill.description;
        if (std.mem.indexOfAny(u8, desc, "\n\t\r")) |i| desc = desc[0..i];

        // Skills carry no explicit argument-hint frontmatter today, so the hint
        // is synthesized as `[arg1] [arg2]` from the named `arguments` slots when
        // present. Fold it into the secondary description like custom commands.
        const hint = try suggestionArgumentHint(allocator, "", skill.arg_names);
        defer allocator.free(hint);

        if (hint.len > 0 and desc.len > 0) {
            try out.writer().print("skill\t{s}\t{s}\t{s} {s}\n", .{ command, label, desc, hint });
        } else if (hint.len > 0) {
            try out.writer().print("skill\t{s}\t{s}\t{s}\n", .{ command, label, hint });
        } else {
            try out.writer().print("skill\t{s}\t{s}\t{s}\n", .{ command, label, desc });
        }
    }
    return out.toOwnedSlice();
}

fn renderPromptSuggestionTeams(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const teams_dir_path = try tool_helpers.workspacePathAlloc(allocator, runtime.cwd, tool_helpers.TEAMS_SUBPATH);
    defer allocator.free(teams_dir_path);

    var dir = std.Io.Dir.cwd().openDir(rt.io, teams_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(u8, 0),
        else => return err,
    };
    defer dir.close(rt.io);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var iterator = dir.iterate();
    while (try iterator.next(rt.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".team")) continue;
        const team_path = try std.fs.path.join(allocator, &.{ teams_dir_path, entry.name });
        defer allocator.free(team_path);
        const file_data = try std.Io.Dir.cwd().readFileAlloc(rt.io, team_path, allocator, .limited(16 * 1024));
        defer allocator.free(file_data);

        const fallback_name = entry.name[0 .. entry.name.len - ".team".len];
        const meta = try parseTeamMetadata(allocator, file_data, fallback_name);
        defer {
            allocator.free(meta.name);
            allocator.free(meta.members);
            for (meta.member_rows) |*row| row.deinit(allocator);
            allocator.free(meta.member_rows);
        }
        const label = try std.fmt.allocPrint(allocator, "team:{s}", .{meta.name});
        defer allocator.free(label);
        const description = if (meta.members.len > 0) meta.members else "open local team status";
        try out.writer().print("team\t/teams\t{s}\t{s}\n", .{ label, description });
    }

    return out.toOwnedSlice();
}

fn renderPromptSuggestionMcp(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const servers = try runtime.mcp.list();
    defer mcp_client.freeServers(allocator, servers);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    var total_items: usize = 0;
    const max_items: usize = 64;

    for (servers) |server| {
        if (total_items >= max_items) break;
        // Never connect synchronously from the slash-suggestion path: that runs
        // inside the input loop, and a slow/hanging MCP server would freeze the
        // whole REPL (no keys read after `/`). Only list from already-connected
        // servers. (PRD #534 follow-up)
        if (!runtime.mcp.isConnected(server.name)) continue;
        const resources = runtime.mcp.listResources(server.name) catch continue;
        defer mcp_client.freeResourceInfos(allocator, resources);
        for (resources) |resource| {
            if (total_items >= max_items) break;
            const command = try std.fmt.allocPrint(allocator, "/mcp read {s} {s}", .{ server.name, resource.uri });
            defer allocator.free(command);
            const label = try std.fmt.allocPrint(allocator, "mcp resource:{s}/{s}", .{ server.name, resource.name });
            defer allocator.free(label);
            try out.writer().print(
                "mcp_resource\t{s}\t{s}\t{s}\n",
                .{ command, label, resource.description },
            );
            total_items += 1;
        }
        if (total_items >= max_items) break;
        const prompts = runtime.mcp.listPrompts(server.name) catch continue;
        defer mcp_client.freePromptInfos(allocator, prompts);
        for (prompts) |prompt_info| {
            if (total_items >= max_items) break;
            const command = try std.fmt.allocPrint(allocator, "/mcp prompt {s} {s}", .{ server.name, prompt_info.name });
            defer allocator.free(command);
            const label = try std.fmt.allocPrint(allocator, "mcp prompt:{s}/{s}", .{ server.name, prompt_info.name });
            defer allocator.free(label);
            try out.writer().print(
                "mcp_prompt\t{s}\t{s}\t{s}\n",
                .{ command, label, prompt_info.description },
            );
            total_items += 1;
        }
    }

    return out.toOwnedSlice();
}

fn renderPromptReferenceSuggestions(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    const agents = agents_mod.list(allocator, runtime.cwd) catch null;
    defer if (agents) |list| agents_mod.freeList(allocator, list);
    if (agents) |list| {
        for (list) |agent| {
            const insertion = try std.fmt.allocPrint(allocator, "agent:{s}", .{agent.name});
            defer allocator.free(insertion);
            const label = try std.fmt.allocPrint(allocator, "agent:{s}", .{agent.name});
            defer allocator.free(label);
            try out.writer().print("agent\t{s}\t{s}\t{s}\n", .{ insertion, label, agent.description });
        }
    }

    const teams_dir_path = try tool_helpers.workspacePathAlloc(allocator, runtime.cwd, tool_helpers.TEAMS_SUBPATH);
    defer allocator.free(teams_dir_path);
    var teams_dir = std.Io.Dir.cwd().openDir(rt.io, teams_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (teams_dir) |*dir| dir.close(rt.io);
    if (teams_dir) |*dir| {
        var iterator = dir.iterate();
        while (try iterator.next(rt.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".team")) continue;
            const team_path = try std.fs.path.join(allocator, &.{ teams_dir_path, entry.name });
            defer allocator.free(team_path);
            const file_data = try std.Io.Dir.cwd().readFileAlloc(rt.io, team_path, allocator, .limited(16 * 1024));
            defer allocator.free(file_data);

            const fallback_name = entry.name[0 .. entry.name.len - ".team".len];
            const meta = try parseTeamMetadata(allocator, file_data, fallback_name);
            defer {
                allocator.free(meta.name);
                allocator.free(meta.members);
                for (meta.member_rows) |*row| row.deinit(allocator);
                allocator.free(meta.member_rows);
            }

            const insertion = try std.fmt.allocPrint(allocator, "team:{s}", .{meta.name});
            defer allocator.free(insertion);
            const label = try std.fmt.allocPrint(allocator, "team:{s}", .{meta.name});
            defer allocator.free(label);
            const description = if (meta.members.len > 0) meta.members else "open local team status";
            try out.writer().print("team\t{s}\t{s}\t{s}\n", .{ insertion, label, description });
        }
    }

    const servers = runtime.mcp.list() catch null;
    defer if (servers) |list| mcp_client.freeServers(allocator, list);
    if (servers) |list| {
        for (list) |server| {
            const resources = runtime.mcp.listResources(server.name) catch continue;
            defer mcp_client.freeResourceInfos(allocator, resources);
            for (resources) |resource| {
                const insertion = try std.fmt.allocPrint(allocator, "mcp:{s}:{s}", .{ server.name, resource.uri });
                defer allocator.free(insertion);
                const label = try std.fmt.allocPrint(allocator, "mcp resource:{s}/{s}", .{ server.name, resource.name });
                defer allocator.free(label);
                try out.writer().print("mcp_resource\t{s}\t{s}\t{s}\n", .{ insertion, label, resource.description });
            }

            const prompts = runtime.mcp.listPrompts(server.name) catch continue;
            defer mcp_client.freePromptInfos(allocator, prompts);
            for (prompts) |prompt_info| {
                const insertion = try std.fmt.allocPrint(allocator, "mcp-prompt:{s}/{s}", .{ server.name, prompt_info.name });
                defer allocator.free(insertion);
                const label = try std.fmt.allocPrint(allocator, "mcp prompt:{s}/{s}", .{ server.name, prompt_info.name });
                defer allocator.free(label);
                try out.writer().print("mcp_prompt\t{s}\t{s}\t{s}\n", .{ insertion, label, prompt_info.description });
            }
        }
    }

    return out.toOwnedSlice();
}

fn countManagedBackgroundTasks(allocator: std.mem.Allocator, runtime: *AgentRuntime) !usize {
    const snapshots = try task_mod.listTaskSnapshots(allocator, runtime.cwd, null);
    defer task_mod.freeTaskSnapshots(allocator, snapshots);

    var count: usize = 0;
    for (snapshots) |snapshot| {
        if (isManagedBackgroundTaskActive(snapshot.status)) count += 1;
    }
    return count;
}

fn stopAllManagedBackgroundTasks(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const snapshots = try task_mod.listTaskSnapshots(allocator, runtime.cwd, null);
    defer task_mod.freeTaskSnapshots(allocator, snapshots);

    var stopped: usize = 0;
    for (snapshots) |snapshot| {
        if (!isManagedBackgroundTaskActive(snapshot.status)) continue;
        const result = try task_mod.taskStop(allocator, runtime.cwd, snapshot.id);
        defer allocator.free(result);
        stopped += 1;
    }

    if (stopped == 0) {
        return allocator.dupe(u8, "no managed background tasks running");
    }
    return std.fmt.allocPrint(
        allocator,
        "stopped {d} managed background task{s}",
        .{ stopped, if (stopped == 1) "" else "s" },
    );
}

fn renderRewindPickerData(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const RewindPickerItem = struct {
        history_index: usize,
        prompt: []const u8,
    };

    var count: usize = 0;
    for (runtime.history.view()) |turn| {
        if (turn.role == .user) count += 1;
    }

    const items = try allocator.alloc(RewindPickerItem, count);
    defer allocator.free(items);

    var item_idx: usize = 0;
    for (runtime.history.view(), 0..) |turn, history_index| {
        if (turn.role != .user) continue;
        items[item_idx] = .{
            .history_index = history_index,
            .prompt = turn.content,
        };
        item_idx += 1;
    }

    const Payload = struct {
        initial_selection: usize,
        items: []const RewindPickerItem,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(Payload{
        .initial_selection = if (count > 0) count - 1 else 0,
        .items = items,
    }, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn handleRewindToHistoryIndex(allocator: std.mem.Allocator, runtime: *AgentRuntime, history_index: usize) ![]u8 {
    if (history_index >= runtime.history.len()) {
        return allocator.dupe(u8, "rewind failed: selected prompt no longer exists");
    }
    if (runtime.history.at(history_index).role != .user) {
        return allocator.dupe(u8, "rewind failed: selection is not a user prompt");
    }

    const dropped_total = runtime.history.len() - history_index;
    var dropped_assistant: usize = 0;
    var idx = history_index;
    while (idx < runtime.history.len()) : (idx += 1) {
        if (runtime.history.at(idx).role == .assistant) dropped_assistant += 1;
    }

    runtime.history.truncateFrom(history_index);

    return std.fmt.allocPrint(
        allocator,
        "rewound to before the selected prompt; dropped {d} assistant turn(s) and {d} history entries. Session snapshot on disk is unchanged.",
        .{ dropped_assistant, dropped_total },
    );
}

/// Claude Code's /rewind can restore the CODE as well as the
/// conversation. This is the code-and-conversation variant of
/// handleRewindToHistoryIndex: it rolls the working tree back to the
/// most recent checkpoint (git patches + file copies + untracked
/// removal) AND truncates the in-memory conversation to the selected
/// prompt. The destructive file restore is reached only when the user
/// explicitly opts in via the rewind selector (default stays
/// conversation-only), so this path is never the silent default.
///
/// Mapping a history index to a checkpoint: zcode checkpoints do not
/// carry a per-turn history index, so we resolve the target to the
/// most recent checkpoint (the same default `/session restore` uses).
/// When no checkpoint exists we cannot roll the working tree back, so
/// we degrade gracefully to a conversation-only truncation and say so
/// rather than failing the whole rewind.
fn handleRewindToHistoryIndexWithCode(allocator: std.mem.Allocator, runtime: *AgentRuntime, history_index: usize) ![]u8 {
    if (history_index >= runtime.history.len()) {
        return allocator.dupe(u8, "rewind failed: selected prompt no longer exists");
    }
    if (runtime.history.at(history_index).role != .user) {
        return allocator.dupe(u8, "rewind failed: selection is not a user prompt");
    }

    // restoreCheckpoint replaces the in-memory history with the
    // checkpoint's transcript AND rolls back the workspace, so we do
    // NOT separately truncate here -- the checkpoint defines both the
    // code state and the conversation state at that point.
    const restore_msg = runtime.restoreCheckpoint(null) catch |err| switch (err) {
        // No checkpoint to restore code from: fall back to a
        // conversation-only truncation so the user is not left with a
        // half-applied rewind, and tell them the working tree was left
        // alone because there was nothing to restore it to.
        error.CheckpointNotFound => {
            runtime.history.truncateFrom(history_index);
            return allocator.dupe(
                u8,
                "no checkpoint found to restore code from; rewound the conversation only. Working tree is unchanged.",
            );
        },
        else => return err,
    };
    defer allocator.free(restore_msg);

    return std.fmt.allocPrint(
        allocator,
        "restored code and conversation to the most recent checkpoint. {s}",
        .{restore_msg},
    );
}

fn switchReplModel(allocator: std.mem.Allocator, runtime: *AgentRuntime, requested: []const u8) ![]u8 {
    var target_provider: []const u8 = runtime.active_provider;
    var target_model: []const u8 = requested;

    if (std.mem.indexOfScalar(u8, requested, '/')) |slash_idx| {
        const maybe_provider = std.mem.trim(u8, requested[0..slash_idx], " \t");
        const maybe_model = std.mem.trim(u8, requested[slash_idx + 1 ..], " \t");
        // If the prefix is a known provider name, switch both provider and model.
        // This enables /model local/qwen3:32b, /model openrouter/model-name, etc.
        if (maybe_provider.len > 0 and maybe_model.len > 0 and isKnownProviderName(maybe_provider)) {
            target_provider = maybe_provider;
            target_model = maybe_model;
        }
    }

    // Resolve bare aliases (opus/sonnet/haiku/best/opusplan) and the [1m] suffix
    // into a concrete model id before catalog validation. Custom names pass
    // through with original case. The resolved string owns its own memory; free
    // it once we have duped the final next_model below.
    const resolved = try model_alias.resolve(allocator, target_model);
    defer resolved.deinit(allocator);
    target_model = resolved.model;

    // Gate the resolved model against the availableModels allowlist before any
    // switch/persist. An unset/empty allowlist allows everything (documented
    // zcode deviation). Refuse with a clear message when disallowed; the active
    // model is left unchanged.
    if (!try model_allowlist.isAllowed(allocator, target_model, runtime.cfg.available_models)) {
        return std.fmt.allocPrint(
            allocator,
            "model '{s}' is not in the availableModels allowlist",
            .{requested},
        );
    }

    const models = try resolveModelCatalogForProvider(
        allocator,
        runtime.cfg,
        target_provider,
        target_model,
    );
    defer freeModelCatalog(allocator, models);

    // The [1m] suffix is a context-window modifier, not a distinct catalog
    // entry, so match the catalog against the base id (suffix stripped) while we
    // still store the full target_model below.
    const target_base = if (resolved.one_m and std.mem.endsWith(u8, target_model, "[1m]"))
        target_model[0 .. target_model.len - "[1m]".len]
    else
        target_model;

    var exists = false;
    for (models) |model| {
        if (std.mem.eql(u8, model.id, target_model) or
            std.mem.eql(u8, model.id, target_base) or
            std.mem.eql(u8, model.id, requested))
        {
            exists = true;
            break;
        }
    }

    if (models.len > 0 and !exists) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try out.writer().print("model not found for provider {s}: {s}\n", .{ target_provider, requested });
        try out.writer().writeAll("use /model list to see available ids\n");
        try out.writer().writeAll("or set available_models in config.toml (comma-separated) and restart\n");
        return try out.toOwnedSlice();
    }

    const next_provider = try allocator.dupe(u8, target_provider);
    const next_model = try allocator.dupe(u8, target_model);
    allocator.free(runtime.active_provider);
    runtime.active_provider = next_provider;
    allocator.free(runtime.active_model);
    runtime.active_model = next_model;

    // Invalidate any cached prompt sections keyed on the model
    // axis (reasoning-mode notes, provider-specific instructions,
    // tool-shape hints) so the next turn re-renders against the
    // new model's profile.
    runtime.prompt_sections_registry.invalidate(.model);

    // Update context window from the model catalog so budget/compaction
    // uses the correct size for the new model. Without this, switching
    // from opus-4-6 (200k) to groq/gemma2 (8k) would still use 200k
    // and never trigger compaction, wasting API calls.
    updateContextWindowForModel(allocator, runtime, models);

    // Persist to user config so the choice survives restarts
    config_parse.persistUserConfigField(allocator, "default_provider", runtime.active_provider) catch |err| {
        std.log.warn("failed to persist provider to config: {s}", .{@errorName(err)});
    };
    config_parse.persistUserConfigField(allocator, "default_model", runtime.active_model) catch |err| {
        std.log.warn("failed to persist model to config: {s}", .{@errorName(err)});
    };

    var msg_out = std_io.StringBuilder.init(allocator);
    defer msg_out.deinit();
    try msg_out.writer().print(
        "switched to {s}/{s} (context: {d}k, saved to config)",
        .{ runtime.active_provider, runtime.active_model, @constCast(runtime.cfg).model_context_window / 1000 },
    );

    // Surface a retirement warning when the newly-switched-to model is on the
    // deprecation table for the active provider. Rare path, so a stack buffer
    // formats the static warning without allocating on the hot path.
    var dep_buf: [256]u8 = undefined;
    if (deprecation.getModelDeprecationWarning(&dep_buf, runtime.active_model, runtime.active_provider)) |warning| {
        try msg_out.writer().print("\n{s}", .{warning});
    }

    return try msg_out.toOwnedSlice();
}

const LOOP_USAGE =
    "Usage: /loop [interval] <prompt>\n\n" ++
    "Run a prompt or slash command on a recurring interval.\n" ++
    "Intervals: Ns, Nm, Nh, Nd (e.g. 5m, 30m, 2h, 1d). Default 10m.\n\n" ++
    "Examples:\n" ++
    "  /loop 5m /babysit-prs\n" ++
    "  /loop 30m check the deploy\n" ++
    "  /loop check the deploy every 20m\n";

const LoopArgs = struct { interval: []const u8, prompt: []const u8 };

/// True if `s` matches ^\d+[smhd]$ (a loop interval token like "5m", "2h").
fn isIntervalToken(s: []const u8) bool {
    if (s.len < 2) return false;
    switch (s[s.len - 1]) {
        's', 'm', 'h', 'd' => {},
        else => return false,
    }
    for (s[0 .. s.len - 1]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Parse `[interval] <prompt>` the way Claude Code's loop skill does: a leading
/// interval token wins; else a trailing "every <token>"; else default 10m.
fn parseLoopArgs(args: []const u8) LoopArgs {
    const first_space = std.mem.indexOfScalar(u8, args, ' ') orelse args.len;
    const first = args[0..first_space];
    if (isIntervalToken(first) and first_space < args.len) {
        return .{ .interval = first, .prompt = std.mem.trim(u8, args[first_space..], " \t") };
    }
    if (std.mem.lastIndexOf(u8, args, "every ")) |idx| {
        const after = std.mem.trim(u8, args[idx + 6 ..], " \t");
        const tok_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
        const tok = after[0..tok_end];
        if (isIntervalToken(tok)) {
            return .{ .interval = tok, .prompt = std.mem.trim(u8, args[0..idx], " \t") };
        }
    }
    return .{ .interval = "10m", .prompt = args };
}

/// Convert a loop interval token to a 5-field cron expression, matching Claude
/// Code's interval->cron table. Returns null on a malformed token.
fn intervalToCron(buf: []u8, interval: []const u8) ?[]const u8 {
    if (!isIntervalToken(interval)) return null;
    const unit = interval[interval.len - 1];
    const n = std.fmt.parseInt(u32, interval[0 .. interval.len - 1], 10) catch return null;
    if (n == 0) return null;
    return switch (unit) {
        's' => std.fmt.bufPrint(buf, "*/{d} * * * *", .{@max((n + 59) / 60, 1)}) catch null,
        'm' => if (n <= 59)
            std.fmt.bufPrint(buf, "*/{d} * * * *", .{n}) catch null
        else
            std.fmt.bufPrint(buf, "0 */{d} * * *", .{@max(n / 60, 1)}) catch null,
        'h' => if (n <= 23)
            std.fmt.bufPrint(buf, "0 */{d} * * *", .{n}) catch null
        else
            std.fmt.bufPrint(buf, "0 0 */{d} * *", .{@max(n / 24, 1)}) catch null,
        'd' => std.fmt.bufPrint(buf, "0 0 */{d} * *", .{n}) catch null,
        else => null,
    };
}

/// Render the `/kairos` overview: pending proposals + a tail of the brief.
fn renderKairosOverview(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const kb = @import("core/kairos_brief.zig");
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    const proposals = try kb.listProposals(allocator, cwd);
    defer {
        for (proposals) |*p| p.deinit(allocator);
        allocator.free(proposals);
    }
    try w.print("KAIROS proposals: {d}\n", .{proposals.len});
    for (proposals) |p| {
        const clipped = if (p.prompt.len > 70) p.prompt[0..70] else p.prompt;
        const line_end = std.mem.indexOfScalar(u8, clipped, '\n') orelse clipped.len;
        try w.print("  {s}  {s}\n", .{ p.id, clipped[0..line_end] });
    }
    if (proposals.len > 0) try w.writeAll("\nApprove with: /kairos approve <id>   Dismiss with: /kairos dismiss <id>\n");

    if (kb.readBrief(allocator, cwd)) |brief| {
        defer allocator.free(brief);
        const tail = if (brief.len > 1200) brief[brief.len - 1200 ..] else brief;
        try w.print("\n--- recent brief ---\n{s}\n", .{tail});
    } else {
        try w.writeAll("\n(no brief yet; KAIROS may not have run for this project)\n");
    }
    return out.toOwnedSlice();
}

fn handleThemeCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    const current_setting = ui_theme.parseThemeSetting(runtime.cfg.ui_theme) orelse .dark;
    const current_resolved = ui_theme.resolveSetting(current_setting);

    if (std.mem.eql(u8, command, "/theme") or std.mem.eql(u8, command, "/theme list")) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try out.writer().print(
            "theme setting: {s}\nresolved theme: {s}\nsyntax highlighting: {s}\n\navailable themes:\n",
            .{
                ui_theme.formatThemeSetting(current_setting),
                ui_theme.formatThemeName(current_resolved),
                if (runtime.cfg.ui_highlight_code_blocks) "on" else "off",
            },
        );
        const items = [_]ui_theme.ThemeSetting{
            .auto,
            .dark,
            .light,
            .dark_daltonized,
            .light_daltonized,
            .dark_ansi,
            .light_ansi,
        };
        for (items) |item| {
            const marker = if (item == current_setting) "*" else " ";
            const resolved = ui_theme.resolveSetting(item);
            try out.writer().print("  {s} {s}", .{ marker, ui_theme.formatThemeSetting(item) });
            if (item == .auto) {
                try out.writer().print("  -> {s}", .{ui_theme.formatThemeName(resolved)});
            }
            try out.writer().writeByte('\n');
        }
        try out.writer().writeAll("\nuse /theme <name> to persist a theme, or /theme syntax on|off to control code highlighting");
        return @as(?[]u8, try out.toOwnedSlice());
    }

    if (std.mem.eql(u8, command, "/theme current")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "theme setting: {s}\nresolved theme: {s}\nsyntax highlighting: {s}",
            .{
                ui_theme.formatThemeSetting(current_setting),
                ui_theme.formatThemeName(current_resolved),
                if (runtime.cfg.ui_highlight_code_blocks) "on" else "off",
            },
        ));
    }

    if (std.mem.eql(u8, command, "/theme syntax")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "syntax highlighting: {s}\nusage: /theme syntax on|off",
            .{if (runtime.cfg.ui_highlight_code_blocks) "on" else "off"},
        ));
    }

    if (std.mem.startsWith(u8, command, "/theme syntax ")) {
        const arg = std.mem.trim(u8, command["/theme syntax ".len..], " \t");
        const enabled = if (std.mem.eql(u8, arg, "on"))
            true
        else if (std.mem.eql(u8, arg, "off"))
            false
        else
            return @as(?[]u8, try allocator.dupe(u8, "usage: /theme syntax on|off"));

        mutable_cfg.ui_highlight_code_blocks = enabled;
        config_parse.persistUserConfigField(allocator, "ui_highlight_code_blocks", if (enabled) "true" else "false") catch |err| {
            std.log.warn("failed to persist syntax highlighting setting: {s}", .{@errorName(err)});
        };

        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "syntax highlighting: {s} (saved to config)",
            .{if (enabled) "on" else "off"},
        ));
    }

    const arg = std.mem.trim(u8, command["/theme ".len..], " \t");
    const next_setting = ui_theme.parseThemeSetting(arg) orelse {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "unknown theme: {s}\nuse /theme list to see available themes",
            .{arg},
        ));
    };
    const resolved = ui_theme.resolveSetting(next_setting);
    try mutable_cfg.setOwnedString(allocator, &mutable_cfg.ui_theme, ui_theme.formatThemeSetting(next_setting));
    config_parse.persistUserConfigField(allocator, "ui_theme", ui_theme.formatThemeSetting(next_setting)) catch |err| {
        std.log.warn("failed to persist theme setting: {s}", .{@errorName(err)});
    };

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "theme set to: {s} (resolved: {s}, saved to config)",
        .{ ui_theme.formatThemeSetting(next_setting), ui_theme.formatThemeName(resolved) },
    ));
}

fn handleBriefCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    const current = runtime.cfg.ui_brief_mode;

    if (std.mem.eql(u8, command, "/brief current")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "brief mode: {s}\nview: dense transcript with collapsed assistant replies",
            .{if (current) "on" else "off"},
        ));
    }

    const next = blk: {
        if (std.mem.eql(u8, command, "/brief")) break :blk !current;
        if (std.mem.startsWith(u8, command, "/brief ")) {
            const arg = std.mem.trim(u8, command["/brief ".len..], " \t");
            if (std.mem.eql(u8, arg, "on")) break :blk true;
            if (std.mem.eql(u8, arg, "off")) break :blk false;
        }
        return @as(?[]u8, try allocator.dupe(u8, "usage: /brief [on|off|current]"));
    };

    mutable_cfg.ui_brief_mode = next;
    config_parse.persistUserConfigField(allocator, "ui_brief_mode", if (next) "true" else "false") catch |err| {
        std.log.warn("failed to persist brief mode setting: {s}", .{@errorName(err)});
    };

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "brief mode: {s} (saved to config)\nview: dense transcript with collapsed assistant replies",
        .{if (next) "on" else "off"},
    ));
}

fn handleDensityCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    const current = repl.parseUiDensity(runtime.cfg.ui_density) orelse .full;

    if (std.mem.eql(u8, command, "/density current")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "ui density: {s}\nlayout: {s}",
            .{
                repl.formatUiDensity(current),
                if (current == .clean) "minimal top/status chrome for repeat users" else "full context + compose guidance",
            },
        ));
    }

    const next = blk: {
        if (std.mem.eql(u8, command, "/density")) {
            break :blk if (current == .full) repl.UiDensity.clean else repl.UiDensity.full;
        }
        if (std.mem.startsWith(u8, command, "/density ")) {
            const arg = std.mem.trim(u8, command["/density ".len..], " \t");
            break :blk repl.parseUiDensity(arg) orelse {
                return @as(?[]u8, try allocator.dupe(u8, "usage: /density [full|clean|current]"));
            };
        }
        return @as(?[]u8, try allocator.dupe(u8, "usage: /density [full|clean|current]"));
    };

    try mutable_cfg.setOwnedString(allocator, &mutable_cfg.ui_density, repl.formatUiDensity(next));
    config_parse.persistUserConfigField(allocator, "ui_density", repl.formatUiDensity(next)) catch |err| {
        std.log.warn("failed to persist ui density setting: {s}", .{@errorName(err)});
    };

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "ui density: {s} (saved to config)\nlayout: {s}",
        .{
            repl.formatUiDensity(next),
            if (next == .clean) "minimal top/status chrome for repeat users" else "full context + compose guidance",
        },
    ));
}

fn handleVimCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
    const current = runtime.cfg.ui_vim_mode;
    if (std.mem.eql(u8, command, "/vim current")) {
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "vim mode: {s}\nediting: insert/normal prompt controls in the fullscreen REPL",
            .{if (current) "on" else "off"},
        ));
    }

    const next = blk: {
        if (std.mem.eql(u8, command, "/vim")) break :blk !current;
        if (std.mem.startsWith(u8, command, "/vim ")) {
            const arg = std.mem.trim(u8, command["/vim ".len..], " \t");
            if (std.mem.eql(u8, arg, "on")) break :blk true;
            if (std.mem.eql(u8, arg, "off")) break :blk false;
        }
        return @as(?[]u8, try allocator.dupe(u8, "usage: /vim [on|off|current]"));
    };

    mutable_cfg.ui_vim_mode = next;
    config_parse.persistUserConfigField(allocator, "ui_vim_mode", if (next) "true" else "false") catch |err| {
        std.log.warn("failed to persist vim mode setting: {s}", .{@errorName(err)});
    };

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "vim mode: {s} (saved to config)\nediting: Esc normal, i/a insert, dd delete line, yy yank line, p paste",
        .{if (next) "on" else "off"},
    ));
}

fn renderFormatStatus(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    if (runtime.pending_response_schema) |schema| {
        return std.fmt.allocPrint(
            allocator,
            "response format: active ({d} bytes)\n  schema: {s}\n  Use /format clear to remove.",
            .{ schema.len, schema },
        );
    }
    return allocator.dupe(
        u8,
        "response format: none\n" ++
            "  /format json <schema>   enforce a JSON schema on the next turn\n" ++
            "  /format clear           clear the pending schema\n" ++
            "  Supported on OpenAI-compatible providers (openai, azure, deepseek, groq, openrouter, local).",
    );
}

fn renderEffortStatus(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const current = runtime.reasoning_effort;
    // Render a small ladder of levels so the user can see at a glance
    // which is active. The left column is the circle glyph (○◐●◉
    // from figures.ts), the center is the label, the right is the
    // description. The active row is marked with a right-arrow.
    const levels = [_]types.ReasoningEffort{ .auto, .low, .medium, .high, .max };
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print(
        "reasoning effort: {s} {s}\n  {s}\n\n",
        .{ current.glyph(), current.toString(), current.description() },
    );
    for (levels) |level| {
        const marker = if (level == current) "\xe2\x86\x92" else " ";
        try out.writer().print(
            "  {s} {s} {s: <7}  {s}\n",
            .{ marker, level.glyph(), level.toString(), level.description() },
        );
    }
    // commands-sweep-08: when CLAUDE_CODE_EFFORT_LEVEL is set, surface that it
    // overrides the session value (it wins at apply time). The current level
    // above already reflects the resolved precedence; this line tells the user
    // WHY it cannot be changed via /effort until the env var is cleared.
    switch (effort_level_mod.envOverride()) {
        .none => {},
        .force_auto => {
            const raw = @import("core/env.zig").getenv(effort_level_mod.ENV_VAR) orelse "auto";
            try out.writer().print(
                "\n{s}={s} forces auto (clears any persisted level) for this session.\n",
                .{ effort_level_mod.ENV_VAR, raw },
            );
        },
        .level => |lvl| {
            const raw = @import("core/env.zig").getenv(effort_level_mod.ENV_VAR) orelse lvl.toString();
            try out.writer().print(
                "\n{s}={s} overrides this session (resolved to {s}); clear it to use the /effort setting.\n",
                .{ effort_level_mod.ENV_VAR, raw, lvl.toString() },
            );
        },
    }
    try out.writer().writeAll("\nUsage: /effort <low|medium|high|max|auto>");
    return out.toOwnedSlice();
}

/// Handle the palette form of `/color <name|reset>` (commands-sweep-03).
/// Persists the chosen accent color to the `<id>.color` session sidecar so
/// it survives restart. Returns the user-facing message. Factored out of the
/// dispatch switch so it can be unit-tested against a tmp-dir store without a
/// full runtime.
///
/// Note: the chosen color is persisted and reported, but zcode's prompt-bar
/// renderer uses a single fixed brand accent and does not yet apply a
/// per-session accent. The visual wiring is a documented follow-up.
fn handleColorPalette(
    allocator: std.mem.Allocator,
    store: *session_store_mod.Store,
    session_id: []const u8,
    arg: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, arg, " \t");

    // No argument or unrecognized token -> list the palette.
    if (trimmed.len == 0) {
        const csv = try agent_color_mod.paletteCsv(allocator);
        defer allocator.free(csv);
        return std.fmt.allocPrint(allocator, "Please provide a color. Available colors: {s}, default", .{csv});
    }

    // Reset alias -> clear the stored color (delete the sidecar).
    if (agent_color_mod.isReset(trimmed)) {
        try store.setColor(session_id, "");
        return allocator.dupe(u8, "Session color reset to default");
    }

    // Valid palette color -> persist the canonical (lower-cased) name.
    if (agent_color_mod.canonical(trimmed)) |name| {
        try store.setColor(session_id, name);
        return std.fmt.allocPrint(allocator, "Session color set to {s}", .{name});
    }

    // Anything else -> invalid; show the palette.
    const csv = try agent_color_mod.paletteCsv(allocator);
    defer allocator.free(csv);
    return std.fmt.allocPrint(allocator, "Invalid color \"{s}\". Available colors: {s}, default", .{ trimmed, csv });
}

fn handleEffortSet(allocator: std.mem.Allocator, runtime: *AgentRuntime, arg: []const u8) ![]u8 {
    if (arg.len == 0) {
        return renderEffortStatus(allocator, runtime);
    }
    const parsed = types.ReasoningEffort.fromString(arg) orelse {
        return std.fmt.allocPrint(
            allocator,
            "invalid effort: {s}\nValid options: low, medium, high, max, auto",
            .{arg},
        );
    };

    // commands-sweep-08: persist the level so it survives restart, mirroring the
    // reference's updateSettingsForSource('userSettings', { effortLevel }). The
    // canonical lower-case name is written under the `reasoning_effort` config
    // key. `auto` is the "clear the override" choice, so persist "auto" too --
    // a fresh load then resolves through the env/default chain. Persistence is
    // best-effort: a write failure must not block setting the live level.
    config_parse.persistUserConfigField(allocator, "reasoning_effort", parsed.toString()) catch |err| {
        std.log.warn("effort: failed to persist reasoning_effort: {s}", .{@errorName(err)});
    };

    // The env override wins at apply time, so the live runtime level reflects
    // the resolved precedence (env > the just-chosen level), not the raw choice.
    const override = effort_level_mod.envOverride();
    runtime.reasoning_effort = effort_level_mod.resolveApplied(override, parsed);

    const env_raw = @import("core/env.zig").getenv(effort_level_mod.ENV_VAR);
    return effort_level_mod.buildSetMessage(allocator, parsed, override, env_raw);
}

/// Claude Code's /clear: drop the in-memory conversation so the next
/// turn starts fresh in the same session slot. Session history on disk
/// is left untouched; only the live history buffer and recent outcomes
/// snapshot are cleared. Aliases: /reset, /new.
fn handleClearConversation(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const cleared_count = runtime.history.len();
    runtime.history.clearInMemory();
    // Phase 10 Task 5 (memory-01): reset the turn-end extraction cursor so a
    // cleared conversation starts a fresh extraction window (matches the
    // reference resetting lastMemoryMessageUuid on a wiped transcript).
    runtime.extract_state.reset();
    // Phase 10 Task 6 (memory-05): reset the per-session summarizer cursors so a
    // cleared conversation starts a fresh init/threshold window.
    runtime.session_mem_state.reset();
    // Drop the recent-outcomes ring so the next prompt doesn't see
    // stale context from the old conversation.
    for (runtime.snapshot.recent_tool_outcomes) |outcome| {
        runtime.allocator.free(outcome);
    }
    runtime.allocator.free(runtime.snapshot.recent_tool_outcomes);
    runtime.snapshot.recent_tool_outcomes = try runtime.allocator.alloc([]const u8, 0);

    // Also wipe the terminal scrollback so the old conversation
    // text disappears from the user's view. Matches Claude Code's
    // /clear which emits ESC[2J+ESC[3J+ESC[H at ink/clearTerminal.ts.
    // Gate on isatty so we don't spray escape bytes into a pipe or
    // log redirect.
    if (std.c.isatty(std.Io.File.stdout().handle) != 0) {
        std.Io.File.stdout().writeStreamingAll(rt.io, format_mod.clearTerminalSequence()) catch {};
    }

    return std.fmt.allocPrint(
        allocator,
        "cleared {d} in-memory turn(s); session {s} on disk is untouched",
        .{ cleared_count, runtime.session_id },
    );
}

/// Claude Code's /release-notes: show recent changes so users can
/// see what shipped since they last updated. Uses the CHANGELOG.md
/// content baked into the binary at build time
/// (build_options.changelog via readChangelogContent in build.zig)
/// and parses it through core/changelog.zig. Falls back to the
/// older git-log reader when the embedded changelog is empty
/// (build failed to read CHANGELOG.md, or the installed binary
/// predates this feature) so existing users never regress to
/// "no release notes available".
fn renderReleaseNotes(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    _ = runtime;

    const changelog_mod = @import("core/changelog.zig");
    const embedded: []const u8 = build_options.changelog;

    if (embedded.len > 0) {
        const entries = changelog_mod.parseChangelog(allocator, embedded) catch |err| {
            return std.fmt.allocPrint(
                allocator,
                "release-notes: failed to parse embedded CHANGELOG.md ({s}). See the full changelog in the README.",
                .{@errorName(err)},
            );
        };
        defer changelog_mod.freeEntries(allocator, entries);

        if (entries.len > 0) {
            var out = std_io.StringBuilder.init(allocator);
            errdefer out.deinit();
            try out.writer().print("Recent changes ({s}):\n\n", .{build_options.app_version});
            const formatted = try changelog_mod.formatRecent(allocator, entries, 5);
            defer allocator.free(formatted);
            try out.writer().writeAll(formatted);
            return out.toOwnedSlice();
        }
    }

    // Fallback: no embedded changelog (old build) -- read the last
    // 20 git commits. Keeps existing users covered when they
    // haven't rebuilt since this feature shipped.
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "log", "--pretty=format:%h %s", "-n", "20" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "release-notes: could not read git log ({s}).\nSee the full changelog in the README.",
            .{@errorName(err)},
        );
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            return allocator.dupe(u8, "release-notes: git log failed; not in a git repository?");
        },
        else => return allocator.dupe(u8, "release-notes: git log terminated abnormally"),
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("Recent changes ({s}):\n", .{build_options.app_version});
    var line_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    var shown: usize = 0;
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try out.writer().print("  \xc2\xb7 {s}\n", .{trimmed});
        shown += 1;
        if (shown >= 20) break;
    }
    if (shown == 0) try out.writer().writeAll("  (no commits found)\n");
    return out.toOwnedSlice();
}

/// Claude Code's /keybindings: make sure ~/.zcode/keybindings.json
/// exists (writing a template with the default bindings if it
/// doesn't), then try to open it in the user's $EDITOR so they can
/// edit it. The reference uses 'wx' flag for exclusive-create to
/// avoid a TOCTOU race; zcode uses O_EXCL via CreateFlags.exclusive.
fn openKeybindingsInEditor(allocator: std.mem.Allocator) ![]u8 {
    const keybindings_mod = @import("cli/keybindings.zig");
    const path = try keybindings_mod.keybindingsPath(allocator);
    defer allocator.free(path);

    // Ensure the parent directory exists.
    if (std.fs.path.dirname(path)) |parent| {
        std.Io.Dir.cwd().createDirPath(rt.io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return std.fmt.allocPrint(
                allocator,
                "keybindings: could not create parent directory ({s})",
                .{@errorName(err)},
            ),
        };
    }

    // Create the file with O_EXCL so we don't stomp an existing one.
    var created = false;
    if (std.Io.Dir.cwd().createFile(rt.io, path, .{ .exclusive = true, .permissions = std.Io.File.Permissions.fromMode(0o600) })) |file| {
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, defaultKeybindingsTemplate);
        created = true;
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return std.fmt.allocPrint(
            allocator,
            "keybindings: could not create {s} ({s})",
            .{ path, @errorName(err) },
        ),
    }

    // Pick an editor: $VISUAL beats $EDITOR beats `vi`.
    var editor_buf: [256]u8 = undefined;
    const editor = pickEditor(&editor_buf);

    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ editor, path },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "{s} {s}. Could not open in editor ({s}): {s}",
            .{ if (created) "Created" else "Opened", path, editor, @errorName(err) },
        );
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return std.fmt.allocPrint(
        allocator,
        "{s} {s} in {s}",
        .{ if (created) "Created" else "Opened", path, editor },
    );
}

fn pickEditor(buf: *[256]u8) []const u8 {
    if (@import("core/env.zig").getenv("VISUAL")) |v| {
        if (v.len > 0 and v.len < buf.len) {
            @memcpy(buf[0..v.len], v);
            return buf[0..v.len];
        }
    }
    if (@import("core/env.zig").getenv("EDITOR")) |e| {
        if (e.len > 0 and e.len < buf.len) {
            @memcpy(buf[0..e.len], e);
            return buf[0..e.len];
        }
    }
    return "vi";
}

/// Default keybindings template written on first /keybindings.
/// Mirrors the defaults from src/cli/keybindings.zig's parser; each
/// action has a comment so the user can discover what's available
/// without grepping the source. The template uses the same key
/// naming convention as the parser (tab, shift_tab, enter, esc,
/// ctrl+c, alt+backspace, etc).
const defaultKeybindingsTemplate =
    \\{
    \\  "$schema": "https://www.schemastore.org/claude-code-keybindings.json",
    \\  "$docs": "https://code.claude.com/docs/en/keybindings",
    \\  "_comment": "zcode keybindings. Edit and run /reload to apply without restarting.",
    \\  "bindings": [
    \\    {
    \\      "context": "Global",
    \\      "bindings": {
    \\        "ctrl+o": "app:toggleTranscript",
    \\        "ctrl+t": "app:toggleTodos",
    \\        "ctrl+b": "app:toggleBrief",
    \\        "ctrl+shift+b": "app:toggleBrief",
    \\        "ctrl+l": "app:redraw",
    \\        "ctrl+f": "app:globalSearch",
    \\        "ctrl+shift+f": "app:globalSearch",
    \\        "cmd+shift+f": "app:globalSearch",
    \\        "ctrl+p": "app:quickOpen",
    \\        "ctrl+shift+p": "app:quickOpen",
    \\        "cmd+shift+p": "app:quickOpen",
    \\        "ctrl+r": "history:search"
    \\      }
    \\    },
    \\    {
    \\      "context": "Chat",
    \\      "bindings": {
    \\        "enter": "chat:submit",
    \\        "shift+enter": "chat:newline",
    \\        "shift+tab": "chat:cycleMode",
    \\        "up": "history:previous",
    \\        "down": "history:next",
    \\        "ctrl+x ctrl+e": "chat:externalEditor",
    \\        "ctrl+x ctrl+k": "chat:killAgents",
    \\        "ctrl+g": "chat:externalEditor",
    \\        "ctrl+s": "chat:stash",
    \\        "ctrl+v": "chat:imagePaste",
    \\        "shift+up": "chat:messageActions",
    \\        "alt+p": "chat:modelPicker",
    \\        "alt+o": "chat:fastMode",
    \\        "alt+t": "chat:thinkingToggle",
    \\        "ctrl+_": "chat:undo",
    \\        "ctrl+shift+-": "chat:undo",
    \\        "ctrl+u": "chat:clearLine",
    \\        "cmd+backspace": "chat:clearLine",
    \\        "ctrl+w": "chat:deletePrevWord",
    \\        "alt+backspace": "chat:deletePrevWord",
    \\        "backspace": "chat:backspace"
    \\      }
    \\    },
    \\    {
    \\      "context": "Autocomplete",
    \\      "bindings": {
    \\        "tab": "autocomplete:accept",
    \\        "escape": "autocomplete:dismiss",
    \\        "up": "autocomplete:previous",
    \\        "down": "autocomplete:next"
    \\      }
    \\    },
    \\    {
    \\      "context": "PromptSuggestions",
    \\      "bindings": {
    \\        "up": "prompt:previous",
    \\        "down": "prompt:next",
    \\        "ctrl+p": "prompt:previous",
    \\        "ctrl+n": "prompt:next",
    \\        "enter": "prompt:open",
    \\        "tab": "prompt:open",
    \\        "right": "prompt:open",
    \\        "escape": "prompt:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "PromptQueue",
    \\      "bindings": {
    \\        "up": "prompt:previous",
    \\        "down": "prompt:next",
    \\        "ctrl+p": "prompt:previous",
    \\        "ctrl+n": "prompt:next",
    \\        "enter": "prompt:open",
    \\        "backspace": "prompt:dismiss",
    \\        "x": "prompt:dismiss",
    \\        "escape": "prompt:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "PromptStash",
    \\      "bindings": {
    \\        "up": "prompt:previous",
    \\        "down": "prompt:next",
    \\        "ctrl+p": "prompt:previous",
    \\        "ctrl+n": "prompt:next",
    \\        "enter": "prompt:open",
    \\        "backspace": "prompt:dismiss",
    \\        "x": "prompt:dismiss",
    \\        "escape": "prompt:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "PromptNotifications",
    \\      "bindings": {
    \\        "up": "prompt:previous",
    \\        "down": "prompt:next",
    \\        "ctrl+p": "prompt:previous",
    \\        "ctrl+n": "prompt:next",
    \\        "enter": "prompt:open",
    \\        "backspace": "prompt:dismiss",
    \\        "x": "prompt:dismiss",
    \\        "escape": "prompt:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "Attachments",
    \\      "bindings": {
    \\        "right": "attachments:next",
    \\        "left": "attachments:previous",
    \\        "backspace": "attachments:remove",
    \\        "down": "attachments:exit",
    \\        "escape": "attachments:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "Footer",
    \\      "bindings": {
    \\        "up": "footer:up",
    \\        "ctrl+p": "footer:up",
    \\        "down": "footer:down",
    \\        "ctrl+n": "footer:down",
    \\        "right": "footer:next",
    \\        "left": "footer:previous",
    \\        "enter": "footer:openSelected",
    \\        "escape": "footer:clearSelection"
    \\      }
    \\    },
    \\    {
    \\      "context": "Confirmation",
    \\      "bindings": {
    \\        "y": "confirm:yes",
    \\        "n": "confirm:no",
    \\        "enter": "confirm:yes",
    \\        "escape": "confirm:no",
    \\        "up": "confirm:previous",
    \\        "down": "confirm:next",
    \\        "tab": "confirm:nextField",
    \\        "space": "confirm:toggle",
    \\        "shift+tab": "confirm:cycleMode",
    \\        "ctrl+e": "confirm:toggleExplanation",
    \\        "ctrl+d": "permission:toggleDebug"
    \\      }
    \\    },
    \\    {
    \\      "context": "Transcript",
    \\      "bindings": {
    \\        "ctrl+e": "transcript:toggleShowAll",
    \\        "ctrl+c": "transcript:exit",
    \\        "escape": "transcript:exit",
    \\        "q": "transcript:exit"
    \\      }
    \\    },
    \\    {
    \\      "context": "HistorySearch",
    \\      "bindings": {
    \\        "ctrl+r": "historySearch:next",
    \\        "escape": "historySearch:accept",
    \\        "tab": "historySearch:accept",
    \\        "ctrl+c": "historySearch:cancel",
    \\        "enter": "historySearch:execute"
    \\      }
    \\    },
    \\    {
    \\      "context": "ThemePicker",
    \\      "bindings": {
    \\        "ctrl+t": "theme:toggleSyntaxHighlighting"
    \\      }
    \\    },
    \\    {
    \\      "context": "ThinkingDialog",
    \\      "bindings": {
    \\        "y": "confirm:yes",
    \\        "n": "confirm:no",
    \\        "enter": "confirm:yes",
    \\        "escape": "confirm:no",
    \\        "up": "confirm:previous",
    \\        "down": "confirm:next"
    \\      }
    \\    },
    \\    {
    \\      "context": "AutoModeDialog",
    \\      "bindings": {
    \\        "y": "confirm:yes",
    \\        "n": "confirm:no",
    \\        "enter": "confirm:yes",
    \\        "escape": "confirm:no",
    \\        "up": "confirm:previous",
    \\        "down": "confirm:next"
    \\      }
    \\    },
    \\    {
    \\      "context": "TeamsDialog",
    \\      "bindings": {
    \\        "up": "select:previous",
    \\        "down": "select:next",
    \\        "k": "select:previous",
    \\        "j": "select:next",
    \\        "ctrl+p": "select:previous",
    \\        "ctrl+n": "select:next",
    \\        "enter": "select:accept",
    \\        "escape": "select:cancel"
    \\      }
    \\    },
    \\    {
    \\      "context": "BridgeDialog",
    \\      "bindings": {
    \\        "up": "select:previous",
    \\        "down": "select:next",
    \\        "k": "select:previous",
    \\        "j": "select:next",
    \\        "ctrl+p": "select:previous",
    \\        "ctrl+n": "select:next",
    \\        "enter": "select:accept",
    \\        "escape": "select:cancel"
    \\      }
    \\    },
    \\    {
    \\      "context": "Select",
    \\      "bindings": {
    \\        "up": "select:previous",
    \\        "down": "select:next",
    \\        "k": "select:previous",
    \\        "j": "select:next",
    \\        "enter": "select:accept",
    \\        "escape": "select:cancel"
    \\      }
    \\    },
    \\    {
    \\      "context": "MessageSelector",
    \\      "bindings": {
    \\        "up": "messageSelector:up",
    \\        "down": "messageSelector:down",
    \\        "ctrl+p": "messageSelector:up",
    \\        "ctrl+n": "messageSelector:down",
    \\        "ctrl+up": "messageSelector:top",
    \\        "ctrl+down": "messageSelector:bottom",
    \\        "shift+up": "messageSelector:top",
    \\        "shift+down": "messageSelector:bottom",
    \\        "enter": "messageSelector:select"
    \\      }
    \\    },
    \\    {
    \\      "context": "MessageActions",
    \\      "bindings": {
    \\        "up": "messageActions:prev",
    \\        "down": "messageActions:next",
    \\        "ctrl+up": "messageActions:top",
    \\        "ctrl+down": "messageActions:bottom",
    \\        "shift+up": "messageActions:prevUser",
    \\        "shift+down": "messageActions:nextUser",
    \\        "enter": "messageActions:enter",
    \\        "c": "messageActions:c",
    \\        "escape": "messageActions:escape"
    \\      }
    \\    }
    \\  ]
    \\}
    \\
;

/// Claude Code's /reload-plugins: in the reference this reloads
/// plugin/skill/agent/hook/MCP registries from disk. zcode loads
/// all of these lazily on demand -- plugins.list() re-reads the
/// filesystem every time it's called -- so there's no in-memory
/// cache to invalidate. Instead we treat /reload-plugins as an
/// on-demand "rescan and report" command that walks each registry,
/// reports the counts, and confirms that whatever the user just
/// edited will be picked up on the next tool round.
fn rescanPluginsAndReport(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const plugins_count = blk: {
        const specs = plugins_mod.list(allocator, runtime.cwd) catch break :blk @as(usize, 0);
        defer {
            for (specs) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(specs);
        }
        break :blk specs.len;
    };

    const skills_count = blk: {
        const specs = skills_mod.list(allocator, runtime.cwd) catch break :blk @as(usize, 0);
        defer {
            for (specs) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(specs);
        }
        break :blk specs.len;
    };

    const agents_count = blk: {
        const specs = agents_mod.list(allocator, runtime.cwd) catch break :blk @as(usize, 0);
        defer {
            for (specs) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(specs);
        }
        break :blk specs.len;
    };

    const hooks_count = blk: {
        const specs = hooks_mod.list(allocator, runtime.cwd) catch break :blk @as(usize, 0);
        defer {
            for (specs) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(specs);
        }
        break :blk specs.len;
    };

    // lsp-10: reinitialize the LSP manager after the plugin rescan so a
    // plugin's LSP server config (lsp-07) edited between sessions is picked up.
    // Best-effort: shuts down the old server set (no leaked children) and
    // rebuilds from the fresh config. A no-op when no manager is installed
    // (headless/`--bare`) and harmless with zero servers (the common case).
    if (lsp_manager.get()) |m| m.reinitialize() catch {};

    return std.fmt.allocPrint(
        allocator,
        "Rescanned: {d} plugin(s) \xc2\xb7 {d} skill(s) \xc2\xb7 {d} agent(s) \xc2\xb7 {d} hook(s).\nEdits in ~/.zcode/{{plugins,skills,agents,hooks}} take effect on the next tool round; no restart needed.",
        .{ plugins_count, skills_count, agents_count, hooks_count },
    );
}

/// Claude Code's /sandbox-toggle (zcode alias /sandbox): view the
/// active sandbox profile and the set of allowed profile names.
/// Matches the reference command's "show status" semantics. The
/// reference has a JSX toggle UI that mutates the profile live;
/// zcode is read-only here because threading a per-session sandbox
/// override through tool dispatch is a bigger refactor than a
/// single iteration -- the user can edit ~/.zcode/config.toml and
/// restart to change it persistently.
fn renderSandboxStatus(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "sandbox profile: {s}\n" ++
            "  known profiles: workspace-write, read-only, no-network, danger-full-access, none\n" ++
            "  change: edit ~/.zcode/config.toml (key: sandbox) and restart zcode",
        .{runtime.cfg.sandbox},
    );
}

/// Claude Code's /pr-comments: fetch comments on the current
/// branch's pull request via the `gh` CLI. Reference dispatches
/// this to the LLM as a templated prompt that tells the model how
/// to call gh; zcode does it directly instead, since we already
/// have the shell primitive and can render JSON to markdown in
/// Zig without bouncing through the model. Falls back to a help
/// message if `gh` isn't installed or there's no PR for the
/// current branch.
fn fetchPrComments(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    _ = runtime;

    // Step 1: get PR number for the current branch.
    const view = std.process.run(allocator, rt.io, .{
        .argv = &.{ "gh", "pr", "view", "--json", "number,headRepository" },
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(32 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "pr-comments: could not run `gh pr view` ({s}). Install the GitHub CLI (`brew install gh`) and run `gh auth login`.",
            .{@errorName(err)},
        );
    };
    defer allocator.free(view.stdout);
    defer allocator.free(view.stderr);
    switch (view.term) {
        .exited => |code| if (code != 0) {
            return std.fmt.allocPrint(
                allocator,
                "pr-comments: `gh pr view` failed (exit {d}).\n{s}",
                .{ code, view.stderr },
            );
        },
        else => return allocator.dupe(u8, "pr-comments: `gh pr view` terminated abnormally"),
    }

    // Step 2: fetch issue-level comments via `gh pr view --comments`.
    // gh renders them as markdown so we don't need to hand-roll JSON
    // parsing. This is a deliberate simplification of the reference's
    // multi-call flow -- we sacrifice per-comment code-diff context
    // for a zero-parsing implementation that ships today. A richer
    // version (paths, diff_hunks, nested replies) is a candidate for
    // a follow-up pass.
    const comments = std.process.run(allocator, rt.io, .{
        .argv = &.{ "gh", "pr", "view", "--comments" },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(512 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "pr-comments: could not run `gh pr view --comments` ({s})",
            .{@errorName(err)},
        );
    };
    defer allocator.free(comments.stdout);
    defer allocator.free(comments.stderr);
    switch (comments.term) {
        .exited => |code| if (code != 0) {
            return std.fmt.allocPrint(
                allocator,
                "pr-comments: `gh pr view --comments` failed (exit {d}).\n{s}",
                .{ code, comments.stderr },
            );
        },
        else => return allocator.dupe(u8, "pr-comments: `gh pr view --comments` terminated abnormally"),
    }

    // gh pr view --comments includes the PR header (title, body) plus
    // the comments below it. Try to find the "--" separator gh prints
    // between the body and the comments and keep just the tail so the
    // output isn't dominated by the PR description.
    const stdout_trim = std.mem.trim(u8, comments.stdout, " \t\r\n");
    if (stdout_trim.len == 0) return allocator.dupe(u8, "pr-comments: (no comments)");
    if (std.mem.indexOf(u8, stdout_trim, "\n--\n")) |sep| {
        const tail = std.mem.trim(u8, stdout_trim[sep + 4 ..], " \t\r\n");
        if (tail.len == 0) return allocator.dupe(u8, "pr-comments: (no comments)");
        return allocator.dupe(u8, tail);
    }
    return allocator.dupe(u8, stdout_trim);
}

/// Derive a human-readable review state from the raw `gh pr view`
/// `reviewDecision` + `isDraft` fields. Ported from claude-code-main/
/// src/utils/ghPrStatus.ts deriveReviewState. Draft PRs always show
/// as "draft" regardless of the review decision (matches the
/// reference).
fn derivePrReviewState(is_draft: bool, review_decision: []const u8) []const u8 {
    if (is_draft) return "draft";
    if (std.mem.eql(u8, review_decision, "APPROVED")) return "approved";
    if (std.mem.eql(u8, review_decision, "CHANGES_REQUESTED")) return "changes_requested";
    return "pending";
}

/// Claude Code's /pr-status equivalent. Shells out to `gh pr view`
/// to read the current branch's PR number, URL, draft flag, state,
/// and review decision. Renders a compact single-line summary so
/// users can check PR review status without leaving the REPL.
///
/// Skip rules match the reference's fetchPrStatus:
///   - Not in a git repo     -> null with a helpful message
///   - Branch == default     -> null (gh returns the last-merged PR
///                              on default branches, which is
///                              misleading)
///   - PR is MERGED or CLOSED -> null (user probably wants to know
///                              about open PRs, not historical ones)
///   - gh not installed       -> null with install hint
fn fetchPrStatus(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    _ = runtime;

    const view = std.process.run(allocator, rt.io, .{
        .argv = &.{
            "gh",
            "pr",
            "view",
            "--json",
            "number,url,reviewDecision,isDraft,headRefName,state",
        },
        .stdout_limit = .limited(32 * 1024),
        .stderr_limit = .limited(32 * 1024),
    }) catch |err| {
        return std.fmt.allocPrint(
            allocator,
            "pr-status: could not run `gh pr view` ({s}). Install the GitHub CLI (`brew install gh`) and run `gh auth login`.",
            .{@errorName(err)},
        );
    };
    defer allocator.free(view.stdout);
    defer allocator.free(view.stderr);
    switch (view.term) {
        .exited => |code| if (code != 0) {
            return std.fmt.allocPrint(
                allocator,
                "pr-status: `gh pr view` failed (exit {d}). Is there an open PR for the current branch?\n{s}",
                .{ code, view.stderr },
            );
        },
        else => return allocator.dupe(u8, "pr-status: `gh pr view` terminated abnormally"),
    }

    // Parse the JSON. Small response, bounded by max_output_bytes.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, view.stdout, .{}) catch {
        return allocator.dupe(u8, "pr-status: could not parse `gh pr view` JSON response");
    };
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.dupe(u8, "pr-status: unexpected JSON shape");
    const obj = parsed.value.object;

    const number: i64 = if (obj.get("number")) |v|
        switch (v) {
            .integer => |n| n,
            else => 0,
        }
    else
        0;
    const url: []const u8 = if (obj.get("url")) |v|
        switch (v) {
            .string => |s| s,
            else => "",
        }
    else
        "";
    const review_decision: []const u8 = if (obj.get("reviewDecision")) |v|
        switch (v) {
            .string => |s| s,
            else => "",
        }
    else
        "";
    const is_draft: bool = if (obj.get("isDraft")) |v|
        switch (v) {
            .bool => |b| b,
            else => false,
        }
    else
        false;
    const state: []const u8 = if (obj.get("state")) |v|
        switch (v) {
            .string => |s| s,
            else => "",
        }
    else
        "";

    // Skip merged/closed PRs -- the reference does the same.
    if (std.mem.eql(u8, state, "MERGED") or std.mem.eql(u8, state, "CLOSED")) {
        return std.fmt.allocPrint(
            allocator,
            "pr-status: PR #{d} is {s}. No open PR for this branch.",
            .{ number, state },
        );
    }

    const review_state = derivePrReviewState(is_draft, review_decision);
    return std.fmt.allocPrint(
        allocator,
        "PR #{d}: {s}\n  state:        {s}\n  review:       {s}\n  url:          {s}",
        .{ number, if (is_draft) "draft" else "open", state, review_state, url },
    );
}

/// Claude Code's /upgrade (zcode alias /update): trigger the self-
/// update flow from inside an interactive session. Claude Code's own
/// /upgrade is gated behind its Max subscription upsell (only useful
/// for claude.ai users); zcode's /upgrade is the OSS equivalent --
/// run the same cmdUpdate entrypoint that the `zcode update` CLI
/// subcommand uses, but capture its progress lines into a buffer so
/// the REPL can render them as a single tool-card output instead of
/// interleaving with the spinner.
///
/// The running binary stays live until the user exits and relaunches
/// zcode; the atomic rename in cmdUpdate guarantees the old image is
/// replaced without corrupting the process image that's currently
/// serving this session.
fn handleUpgrade(allocator: std.mem.Allocator, cfg: *const config_mod.Config) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();

    update_mod.cmdUpdateWithConfig(allocator, cfg, buf.writer()) catch |err| {
        try buf.writer().print(
            "\nupdate failed: {s}\nTry running `zcode update` from a shell for more detail, or re-run /upgrade after checking your network.",
            .{@errorName(err)},
        );
    };
    return buf.toOwnedSlice();
}

/// Claude Code's /usage: a richer view of the session's token usage
/// than /cost. Where /cost focuses on dollar amounts, /usage surfaces
/// the raw token accounting, the active model's context window, and
/// how much of that window is currently in use -- the numbers a power
/// user cares about when they are deciding whether to /compact or
/// /clear. Mirrors the data surface of the reference's Settings Usage
/// tab in plain text (we don't have the Ink UI framework to render
/// the React component one-to-one).
fn renderUsageSummary(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const metrics = runtime.statusMetrics();
    const ctx_window = runtime.cfg.model_context_window;
    const last_total = metrics.last_input_tokens + metrics.last_output_tokens;
    const session_total = metrics.total_input_tokens + metrics.total_output_tokens;
    const pct: f64 = if (ctx_window > 0)
        (@as(f64, @floatFromInt(metrics.last_input_tokens)) * 100.0) / @as(f64, @floatFromInt(ctx_window))
    else
        0.0;

    // Render a Unicode usage bar like `[████████░░░░░░░░░░░░] 42%` so
    // the user gets an at-a-glance view of context utilisation. Ported
    // from claude-code-main/src/components/ContextVisualization.tsx
    // with the React/Ink chrome stripped down to a flat byte buffer.
    const pct_u8: u8 = @intCast(@min(100, @as(usize, @intFromFloat(pct))));
    var bar_buf: [256]u8 = undefined;
    const bar = format_mod.renderUsageBar(&bar_buf, pct_u8, 24);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print(
        "Session usage\n" ++
            "  model            {s}/{s}\n" ++
            "  context window   {d} tokens\n" ++
            "  last turn        in {d}, out {d}, total {d}\n" ++
            "  session total    in {d}, out {d}, total {d}\n" ++
            "  context used     {d:.1}% of window (last prompt)\n" ++
            "  {s}\n\n" ++
            "Tip: /compact to shrink history in place, /clear to start a fresh conversation.",
        .{
            runtime.active_provider,
            runtime.active_model,
            ctx_window,
            metrics.last_input_tokens,
            metrics.last_output_tokens,
            last_total,
            metrics.total_input_tokens,
            metrics.total_output_tokens,
            session_total,
            pct,
            bar,
        },
    );

    // Append actionable suggestions when context usage is high enough
    // to matter. Ported from claude-code-main/src/utils/contextSuggestions.ts
    // so the /usage output does not stop at raw numbers; users get a
    // "here's what to do next" nudge when they're close to a compaction
    // event or running ad-hoc against a too-small window.
    const context_suggestions = @import("core/context_suggestions.zig");
    // Phase 8 (compaction-17): consume-and-clear the one-turn near-capacity
    // suppression set after a successful compaction. The percentage we hold is
    // the stale pre-compaction count until the next API response, so we skip
    // the near-capacity warning exactly once after a /compact.
    const suppress_near_capacity = runtime.suppress_compact_warning;
    runtime.suppress_compact_warning = false;
    const data = context_suggestions.ContextData{
        .percentage = pct_u8,
        .raw_max_tokens = ctx_window,
        .used_tokens = metrics.last_input_tokens,
        .compact_threshold_percent = 60,
        .force_threshold_percent = 80,
        .auto_compact_enabled = true,
        .memory_file_bytes = 0,
        .suppress_near_capacity = suppress_near_capacity,
    };
    const suggestions = try context_suggestions.generate(allocator, data);
    defer context_suggestions.freeSuggestions(allocator, suggestions);
    const rendered = try context_suggestions.renderSuggestionList(allocator, suggestions);
    defer allocator.free(rendered);
    if (rendered.len > 0) {
        try out.writer().writeAll(rendered);
    }

    return out.toOwnedSlice();
}

/// Claude Code's /stickers: opens the Claude Code sticker order page
/// in the default browser. Small easter-egg command but users like
/// feature parity, and it's a zero-cost port.
fn openStickersPage(allocator: std.mem.Allocator) ![]u8 {
    const url = "https://www.stickermule.com/claudecode";
    const argv = switch (@import("builtin").os.tag) {
        .macos => [_][]const u8{ "open", url },
        .linux => [_][]const u8{ "xdg-open", url },
        .windows => [_][]const u8{ "rundll32", "url.dll,FileProtocolHandler", url },
        else => return allocator.dupe(u8, "Visit https://www.stickermule.com/claudecode to order stickers"),
    };
    const result = std.process.run(allocator, rt.io, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024),
        .stderr_limit = .limited(4 * 1024),
    }) catch {
        return std.fmt.allocPrint(
            allocator,
            "failed to open browser. Visit: {s}",
            .{url},
        );
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0) {
        return std.fmt.allocPrint(
            allocator,
            "opening sticker page in browser: {s}",
            .{url},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "failed to open browser. Visit: {s}",
        .{url},
    );
}

/// Claude Code's /rewind (alias /checkpoint): drops the last N
/// assistant turns and any user turns that came after the kept
/// prefix, so the user can retry a different approach from an
/// earlier point. In fullscreen mode zcode now opens a message
/// selector UI and restores the chosen prompt into the editor;
/// this helper remains the numeric fallback used by `/rewind N`
/// and non-fullscreen flows. Default count is 1 (drop the most
/// recent assistant response).
///
/// Session history on disk is left alone -- only the in-memory
/// buffer shrinks -- so /resume still replays the untruncated
/// conversation if the user wants to recover.
fn handleRewind(allocator: std.mem.Allocator, runtime: *AgentRuntime, count: usize) ![]u8 {
    var remaining = count;
    var dropped_assistant: usize = 0;
    var dropped_total: usize = 0;
    var i = runtime.history.len();
    while (i > 0 and remaining > 0) {
        i -= 1;
        const turn = runtime.history.at(i);
        if (turn.role == .assistant) {
            remaining -= 1;
            dropped_assistant += 1;
        }
        dropped_total += 1;
        if (remaining == 0) break;
    }
    if (dropped_assistant == 0) {
        return allocator.dupe(u8, "/rewind: no assistant turns to rewind");
    }
    // Drop the most recent `dropped_total` turns (content freed inside).
    const keep_len = runtime.history.len() - dropped_total;
    runtime.history.truncateFrom(keep_len);
    return std.fmt.allocPrint(
        allocator,
        "rewound {d} assistant turn(s) ({d} history entries total); {d} turn(s) remain in memory. On-disk session untouched.",
        .{ dropped_assistant, dropped_total, runtime.history.len() },
    );
}

/// Claude Code's /thinkback: show the most recent reasoning traces
/// from the model's thinking blocks so the user can audit how the
/// assistant got to its answer. zcode already extracts
/// reasoning_content / thinking tokens into history turns (pass 29),
/// but previously had no surface to view them after the fact. Takes
/// an optional count; default 5.
fn renderThinkback(allocator: std.mem.Allocator, runtime: *AgentRuntime, count: usize) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    // Walk history backwards, pick the last `count` assistant turns
    // that contain a thinking/reasoning marker, then emit them in
    // chronological order so the reader can follow the timeline.
    var hits: [32]usize = undefined;
    var hit_count: usize = 0;
    const take = @min(count, hits.len);
    var i = runtime.history.len();
    while (i > 0 and hit_count < take) {
        i -= 1;
        const turn = runtime.history.at(i);
        if (turn.role != .assistant) continue;
        if (std.mem.indexOf(u8, turn.content, "<thinking>") != null or
            std.mem.indexOf(u8, turn.content, "reasoning:") != null or
            std.mem.indexOf(u8, turn.content, "[thinking]") != null)
        {
            hits[hit_count] = i;
            hit_count += 1;
        }
    }

    if (hit_count == 0) {
        return allocator.dupe(u8, "no thinking traces in the current session history.\n" ++
            "  - Thinking is only emitted by reasoning-capable models (Claude 4 with extended thinking, o1/o3/o4, gpt-5 with reasoning effort set).\n" ++
            "  - Use /effort high to enable more reasoning on a supported model.");
    }

    try out.writer().print(
        "\xe2\x97\x86 Thinking traces ({d} most recent):\n\n",
        .{hit_count},
    );
    var j: usize = hit_count;
    while (j > 0) {
        j -= 1;
        const history_idx = hits[j];
        const turn = runtime.history.at(history_idx);
        try out.writer().print("--- turn {d} ---\n", .{history_idx});
        // Extract and print only the thinking portion if delimited;
        // otherwise print the whole content (capped at 2 KiB so we
        // don't flood the transcript with a huge assistant reply).
        if (std.mem.indexOf(u8, turn.content, "<thinking>")) |start| {
            const after = turn.content[start + "<thinking>".len ..];
            const end = std.mem.indexOf(u8, after, "</thinking>") orelse after.len;
            const slice = after[0..@min(end, 2 * 1024)];
            try out.writer().writeAll(slice);
            try out.writer().writeByte('\n');
        } else {
            const slice = turn.content[0..@min(turn.content.len, 2 * 1024)];
            try out.writer().writeAll(slice);
            try out.writer().writeByte('\n');
        }
        try out.writer().writeByte('\n');
    }
    return out.toOwnedSlice();
}

/// Render the most recent N entries from the in-memory error ring.
/// `max` is the cap; the function shows fewer if the ring contains
/// fewer entries. Layout matches the rest of the slash-command
/// output (header line, then one entry per line with timestamp +
/// message). Caps individual messages at 320 chars so a stack
/// trace doesn't blow up the transcript.
///
/// Used by /errors. Designed to be safe to copy/paste into a bug
/// report.
fn renderRecentErrors(allocator: std.mem.Allocator, max: usize) ![]u8 {
    const error_log = @import("core/error_log.zig");
    const requested = if (max == 0) 25 else max;
    const entries = try error_log.recent(allocator, requested);
    defer error_log.freeRecent(allocator, entries);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (entries.len == 0) {
        try out.writer().writeAll(
            "no errors recorded in the in-memory ring this session.\n" ++
                "  - The ring captures the last 100 errors written via core/error_log.zig.\n" ++
                "  - Long-term audit history lives on disk under the audit log; use the\n" ++
                "    audit-export tooling to read it back.\n" ++
                "  - Use /errors clear to reset the ring; /errors count for a quick total.",
        );
        return out.toOwnedSlice();
    }

    try out.writer().print(
        "\xe2\x97\x86 Recent errors ({d} of {d} in ring):\n\n",
        .{ entries.len, error_log.count() },
    );

    var idx: usize = 0;
    while (idx < entries.len) : (idx += 1) {
        const entry = entries[idx];
        var ts_buf: [32]u8 = undefined;
        const ts_label = format_mod.formatBriefTimestamp(&ts_buf, entry.timestamp, clock.nowSeconds());
        var rel_buf: [32]u8 = undefined;
        const rel_label = format_mod.formatRelativeTimeShort(&rel_buf, entry.timestamp, clock.nowSeconds());

        // Cap each message so a giant stack trace doesn't dominate
        // the output. The full record stays in the ring for callers
        // that want it programmatically; the slash command is for
        // human-readable scanning.
        const max_msg_bytes: usize = 320;
        const slice = if (entry.message.len > max_msg_bytes) entry.message[0..max_msg_bytes] else entry.message;
        const truncated_marker: []const u8 = if (entry.message.len > max_msg_bytes) " \xe2\x80\xa6" else "";

        if (ts_label.len > 0 and rel_label.len > 0) {
            try out.writer().print("  [{s} ({s})] {s}{s}\n", .{ ts_label, rel_label, slice, truncated_marker });
        } else {
            try out.writer().print("  [{d}] {s}{s}\n", .{ entry.timestamp, slice, truncated_marker });
        }
    }

    return out.toOwnedSlice();
}

/// List every file the Read tool has touched in this session,
/// rendered relative to cwd for easy scanning. Ports the /files
/// command from claude-code-main/src/commands/files/files.ts,
/// which surfaces `cacheKeys(context.readFileState)` -- the same
/// structure our core/file.zig read tracker maintains.
fn renderTrackedFiles(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const file_tool = @import("tools/file.zig");
    const snapshot = try file_tool.readTrackerSnapshot(allocator);
    defer file_tool.freeReadTrackerSnapshot(allocator, snapshot);

    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    if (snapshot.len == 0) {
        try out.writer().writeAll(
            "no files in context.\n" ++
                "  - The tracker records every file you've Read or Edited since process start.\n" ++
                "  - Read a file with the Read tool and it will appear here.\n" ++
                "  - The tracker is also used by /enforce-read-before-edit to refuse\n" ++
                "    edits on files the model hasn't actually read yet.",
        );
        return out.toOwnedSlice();
    }

    // Sort deterministically so repeated /files calls produce stable
    // output, regardless of hashmap iteration order.
    std.mem.sort([]const u8, snapshot, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    try out.writer().print("\xe2\x97\x86 Files in context ({d}):\n\n", .{snapshot.len});

    for (snapshot) |abs_path| {
        // Try to relativise against cwd. If the file is inside cwd,
        // show the relative path; otherwise fall back to the absolute
        // path so the user can still see where it lives.
        const display: []const u8 = blk: {
            if (cwd.len > 0 and std.mem.startsWith(u8, abs_path, cwd)) {
                const after = abs_path[cwd.len..];
                if (after.len == 0) break :blk ".";
                if (after[0] == '/') break :blk after[1..];
                // cwd is a prefix but not followed by '/', so it's
                // actually a different path that happens to share
                // a prefix (e.g. cwd=/home/a, file=/home/alpha/x).
                break :blk abs_path;
            }
            break :blk abs_path;
        };
        try out.writer().print("  {s}\n", .{display});
    }

    return out.toOwnedSlice();
}

fn renderReplPreprocessor(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const settings = runtime.resolvedPreprocessorSettings();
    return std.fmt.allocPrint(
        allocator,
        "preprocessor enabled={}\nprovider={s}\nmodel={s}\nmax_output_tokens={d}\nbase_url={s}\napi_key_configured={}\n",
        .{
            runtime.preprocessor_enabled,
            agent_runtime.displayValueOr(settings.provider, "<none>"),
            agent_runtime.displayValueOr(settings.model, "<none>"),
            settings.max_output_tokens,
            agent_runtime.displayValueOr(settings.base_url orelse "", "<env/default>"),
            settings.api_key != null,
        },
    );
}

fn renderReplPreprocessorModels(
    allocator: std.mem.Allocator,
    runtime: *AgentRuntime,
    provider_override: ?[]const u8,
) ![]u8 {
    const provider_name = if (provider_override) |value|
        value
    else if (runtime.preprocessor_provider.len > 0)
        runtime.preprocessor_provider
    else
        runtime.active_provider;

    if (!isKnownProviderName(provider_name)) {
        return std.fmt.allocPrint(allocator, "unknown provider for preprocessor: {s}", .{provider_name});
    }

    const current_model = if (std.mem.eql(u8, provider_name, runtime.preprocessor_provider) and runtime.preprocessor_model.len > 0)
        runtime.preprocessor_model
    else
        "";

    const models = try resolveModelCatalogForProvider(
        allocator,
        runtime.cfg,
        provider_name,
        if (current_model.len > 0) current_model else runtime.active_model,
    );
    defer freeModelCatalog(allocator, models);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    try out.writer().print("preprocessor provider: {s}\n", .{provider_name});
    for (models) |model| {
        const marker = if (current_model.len > 0 and std.mem.eql(u8, model.id, current_model)) "*" else " ";
        try out.writer().print("{s} {s}\tctx={d}\n", .{ marker, model.id, model.context_window });
    }
    if (models.len == 0) {
        try out.writer().writeAll("no models\n");
    }
    try out.writer().writeAll("\nuse /preprocessor <id|provider/id> to switch the session preprocessor\n");
    return out.toOwnedSlice();
}

fn setReplPreprocessorEnabled(allocator: std.mem.Allocator, runtime: *AgentRuntime, enabled: bool) ![]u8 {
    runtime.preprocessor_enabled = enabled;
    if (enabled) {
        if (runtime.preprocessor_provider.len == 0) {
            allocator.free(runtime.preprocessor_provider);
            runtime.preprocessor_provider = try allocator.dupe(u8, runtime.active_provider);
        }
        if (runtime.preprocessor_model.len == 0) {
            allocator.free(runtime.preprocessor_model);
            runtime.preprocessor_model = try allocator.dupe(u8, runtime.active_model);
        }
    }

    const settings = runtime.resolvedPreprocessorSettings();
    return std.fmt.allocPrint(
        allocator,
        "preprocessor {s}: {s}/{s}",
        .{
            if (enabled) "enabled" else "disabled",
            agent_runtime.displayValueOr(settings.provider, "<none>"),
            agent_runtime.displayValueOr(settings.model, "<none>"),
        },
    );
}

fn switchReplPreprocessor(allocator: std.mem.Allocator, runtime: *AgentRuntime, requested: []const u8) ![]u8 {
    var target_provider: []const u8 = if (runtime.preprocessor_provider.len > 0) runtime.preprocessor_provider else runtime.active_provider;
    var target_model: []const u8 = requested;

    if (std.mem.indexOfScalar(u8, requested, '/')) |slash_idx| {
        const maybe_provider = std.mem.trim(u8, requested[0..slash_idx], " \t");
        const maybe_model = std.mem.trim(u8, requested[slash_idx + 1 ..], " \t");
        if (maybe_provider.len > 0 and maybe_model.len > 0 and isKnownProviderName(maybe_provider)) {
            target_provider = maybe_provider;
            target_model = maybe_model;
        }
    }

    const models = try resolveModelCatalogForProvider(
        allocator,
        runtime.cfg,
        target_provider,
        target_model,
    );
    defer freeModelCatalog(allocator, models);

    var exists = false;
    for (models) |model| {
        if (std.mem.eql(u8, model.id, target_model) or std.mem.eql(u8, model.id, requested)) {
            exists = true;
            break;
        }
    }

    if (models.len > 0 and !exists) {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        try out.writer().print("preprocessor model not found for provider {s}: {s}\n", .{ target_provider, requested });
        try out.writer().writeAll("use /preprocessor list to see available ids\n");
        return out.toOwnedSlice();
    }

    const provider_changed = !std.mem.eql(u8, runtime.preprocessor_provider, target_provider);
    const cleared_api_key_override = provider_changed and runtime.preprocessor_api_key.len > 0;
    const cleared_base_url_override = provider_changed and runtime.preprocessor_base_url.len > 0;

    const next_provider = try allocator.dupe(u8, target_provider);
    const next_model = try allocator.dupe(u8, target_model);
    allocator.free(runtime.preprocessor_provider);
    runtime.preprocessor_provider = next_provider;
    allocator.free(runtime.preprocessor_model);
    runtime.preprocessor_model = next_model;
    runtime.preprocessor_enabled = true;

    if (cleared_api_key_override) {
        allocator.free(runtime.preprocessor_api_key);
        runtime.preprocessor_api_key = try allocator.dupe(u8, "");
    }
    if (cleared_base_url_override) {
        allocator.free(runtime.preprocessor_base_url);
        runtime.preprocessor_base_url = try allocator.dupe(u8, "");
    }

    return std.fmt.allocPrint(
        allocator,
        "switched session preprocessor to {s}/{s}{s}{s}",
        .{
            runtime.preprocessor_provider,
            runtime.preprocessor_model,
            if (cleared_api_key_override) " (cleared API key override)" else "",
            if (cleared_base_url_override) " (cleared base URL override)" else "",
        },
    );
}

fn renderReplMcpServers(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    const servers = try runtime.mcp.list();
    defer mcp_client.freeServers(allocator, servers);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (servers.len == 0) {
        try out.writer().writeAll("No MCP servers configured.\n");
    } else {
        try out.writer().print("MCP servers ({d}):\n\n", .{servers.len});
        for (servers, 0..) |server, i| {
            try out.writer().print("{d}. {s}\n   transport: {s}\n", .{ i + 1, server.name, server.transport });
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpTools(allocator: std.mem.Allocator, runtime: *AgentRuntime, server: []const u8) ![]u8 {
    const tools = try runtime.mcp.listTools(server);
    defer mcp_client.freeToolInfos(allocator, tools);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (tools.len == 0) {
        try out.writer().print("No tools found on server {s}.\n", .{server});
    } else {
        try out.writer().print("Tools on {s} ({d}):\n\n", .{ server, tools.len });
        for (tools, 0..) |tool, i| {
            try out.writer().print("{d}. {s}\n", .{ i + 1, tool.name });
            if (tool.description.len > 0) {
                try out.writer().print("   {s}\n", .{tool.description});
            }
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpResources(allocator: std.mem.Allocator, runtime: *AgentRuntime, server: []const u8) ![]u8 {
    const resources = try runtime.mcp.listResources(server);
    defer mcp_client.freeResourceInfos(allocator, resources);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (resources.len == 0) {
        try out.writer().print("No resources found on server {s}.\n", .{server});
    } else {
        try out.writer().print("Resources on {s} ({d}):\n\n", .{ server, resources.len });
        for (resources, 0..) |resource, i| {
            try out.writer().print("{d}. {s}\n", .{ i + 1, resource.name });
            if (resource.uri.len > 0) try out.writer().print("   uri: {s}\n", .{resource.uri});
            if (resource.description.len > 0) try out.writer().print("   {s}\n", .{resource.description});
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpTemplates(allocator: std.mem.Allocator, runtime: *AgentRuntime, server: []const u8) ![]u8 {
    const templates = try runtime.mcp.listResourceTemplates(server);
    defer mcp_client.freeResourceTemplateInfos(allocator, templates);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (templates.len == 0) {
        try out.writer().print("No resource templates found on server {s}.\n", .{server});
    } else {
        try out.writer().print("Resource templates on {s} ({d}):\n\n", .{ server, templates.len });
        for (templates, 0..) |template, i| {
            try out.writer().print("{d}. {s}\n", .{ i + 1, template.name });
            if (template.uri_template.len > 0) try out.writer().print("   template: {s}\n", .{template.uri_template});
            if (template.description.len > 0) try out.writer().print("   {s}\n", .{template.description});
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpRead(allocator: std.mem.Allocator, runtime: *AgentRuntime, server: []const u8, uri: []const u8) ![]u8 {
    const contents = try runtime.mcp.readResource(server, uri);
    defer mcp_client.freeResourceContents(allocator, contents);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (contents.len == 0) {
        try out.writer().print("no MCP resource content returned for {s}\n", .{uri});
        return out.toOwnedSlice();
    }

    for (contents, 0..) |content, idx| {
        if (idx > 0) try out.writer().writeByte('\n');
        try out.writer().print("uri={s}\tmime={s}\n", .{ content.uri, content.mime_type });
        if (content.text) |text| {
            try out.writer().print("{s}\n", .{text});
        } else if (content.blob_base64) |blob| {
            try out.writer().print("<binary {d} bytes base64>\n", .{blob.len});
        } else {
            try out.writer().writeAll("<empty>\n");
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpPrompts(allocator: std.mem.Allocator, runtime: *AgentRuntime, server: []const u8) ![]u8 {
    const prompts = try runtime.mcp.listPrompts(server);
    defer mcp_client.freePromptInfos(allocator, prompts);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (prompts.len == 0) {
        try out.writer().print("no MCP prompts discovered for {s}\n", .{server});
    } else {
        for (prompts) |prompt_info| {
            try out.writer().print("{s}\t{s}\n", .{ prompt_info.name, prompt_info.description });
            for (prompt_info.arguments) |arg| {
                try out.writer().print("  - {s}\trequired={}\t{s}\n", .{ arg.name, arg.required, arg.description });
            }
        }
    }

    return out.toOwnedSlice();
}

fn renderReplMcpPrompt(
    allocator: std.mem.Allocator,
    runtime: *AgentRuntime,
    server: []const u8,
    prompt_name: []const u8,
    arguments_json: ?[]const u8,
) ![]u8 {
    var prompt = try runtime.mcp.getPrompt(server, prompt_name, arguments_json);
    defer prompt.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (prompt.description.len > 0) {
        try out.writer().print("{s}\n", .{prompt.description});
    }
    for (prompt.messages) |message| {
        try out.writer().print("{s}:\n{s}\n", .{ message.role, message.content });
    }

    return out.toOwnedSlice();
}

fn renderReplMcpComplete(
    allocator: std.mem.Allocator,
    runtime: *AgentRuntime,
    server: []const u8,
    ref_json: []const u8,
    argument_name: []const u8,
    value: ?[]const u8,
) ![]u8 {
    var result = try runtime.mcp.complete(server, ref_json, argument_name, value);
    defer result.deinit(allocator);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (result.values.len == 0) {
        try out.writer().print("no MCP completions returned for {s}\n", .{argument_name});
        return out.toOwnedSlice();
    }

    for (result.values) |item| {
        try out.writer().print("{s}\n", .{item});
    }
    if (result.total) |total| {
        try out.writer().print("total={d}\thas_more={}\n", .{ total, result.has_more });
    } else {
        try out.writer().print("has_more={}\n", .{result.has_more});
    }
    return out.toOwnedSlice();
}

fn renderReplMcpNotifications(allocator: std.mem.Allocator, runtime: *AgentRuntime, maybe_server: ?[]const u8) ![]u8 {
    if (maybe_server) |server| {
        runtime.mcp.flushNotifications(server) catch {};
    } else {
        const servers = try runtime.mcp.list();
        defer mcp_client.freeServers(allocator, servers);
        for (servers) |server| {
            runtime.mcp.flushNotifications(server.name) catch {};
        }
    }

    const notifications = try runtime.mcp.takeNotifications(maybe_server);
    defer mcp_client.freeNotificationEvents(allocator, notifications);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (notifications.len == 0) {
        try out.writer().writeAll("no MCP notifications\n");
        return out.toOwnedSlice();
    }

    for (notifications) |notification| {
        try out.writer().print("{s}\t{s}\t{s}\n", .{ notification.server, notification.method, notification.params_json });
    }
    return out.toOwnedSlice();
}

const HeadTail = struct {
    head: []const u8,
    tail: []const u8,
};

fn splitHeadTail(raw: []const u8) HeadTail {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return .{ .head = "", .tail = "" };
    if (std.mem.indexOfAny(u8, trimmed, " \t")) |idx| {
        return .{
            .head = std.mem.trim(u8, trimmed[0..idx], " \t"),
            .tail = std.mem.trim(u8, trimmed[idx + 1 ..], " \t"),
        };
    }
    return .{ .head = trimmed, .tail = "" };
}

// --- /fast command ---

fn handleFastCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const args = if (command.len > "/fast".len) std.mem.trim(u8, command["/fast".len..], " \t") else "";

    // Determine current state: fast = using a "sonnet" or "haiku" or "mini" or "flash" model
    const is_fast = std.mem.indexOf(u8, runtime.active_model, "sonnet") != null or
        std.mem.indexOf(u8, runtime.active_model, "haiku") != null or
        std.mem.indexOf(u8, runtime.active_model, "mini") != null or
        std.mem.indexOf(u8, runtime.active_model, "flash") != null or
        std.mem.indexOf(u8, runtime.active_model, "instant") != null;

    const should_enable = if (std.mem.eql(u8, args, "on")) true else if (std.mem.eql(u8, args, "off")) false else !is_fast;

    if (should_enable and !is_fast) {
        // Switch to fast model for the current provider
        const fast_model = fastModelForProvider(runtime.active_provider);
        const ctx_win = contextWindowForModel(runtime.active_provider, fast_model);
        allocator.free(runtime.active_model);
        runtime.active_model = try allocator.dupe(u8, fast_model);
        @constCast(runtime.cfg).model_context_window = ctx_win;
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "fast mode: on (switched to {s}, context: {d}k)", .{ fast_model, ctx_win / 1000 }));
    } else if (!should_enable and is_fast) {
        // Switch to quality model for the current provider
        const quality_model = qualityModelForProvider(runtime.active_provider);
        const ctx_win = contextWindowForModel(runtime.active_provider, quality_model);
        allocator.free(runtime.active_model);
        runtime.active_model = try allocator.dupe(u8, quality_model);
        @constCast(runtime.cfg).model_context_window = ctx_win;
        return @as(?[]u8, try std.fmt.allocPrint(allocator, "fast mode: off (switched to {s}, context: {d}k)", .{ quality_model, ctx_win / 1000 }));
    }

    return @as(?[]u8, try std.fmt.allocPrint(allocator, "fast mode: {s} (model: {s})", .{ if (is_fast) "on" else "off", runtime.active_model }));
}

fn fastModelForProvider(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return "claude-sonnet-4-6";
    if (std.mem.eql(u8, provider, "openai")) return "gpt-4.1-mini";
    if (std.mem.eql(u8, provider, "gemini")) return "gemini-2.5-flash";
    if (std.mem.eql(u8, provider, "groq")) return "llama-3.1-8b-instant";
    if (std.mem.eql(u8, provider, "deepseek")) return "deepseek-chat";
    return "claude-sonnet-4-6"; // default fallback
}

fn contextWindowForModel(provider: []const u8, model: []const u8) usize {
    if (std.mem.eql(u8, provider, "anthropic")) return 200_000;
    if (std.mem.eql(u8, provider, "openai")) return 128_000;
    if (std.mem.eql(u8, provider, "gemini")) return 1_000_000;
    if (std.mem.eql(u8, provider, "groq")) {
        if (std.mem.indexOf(u8, model, "8b") != null) return 128_000;
        if (std.mem.indexOf(u8, model, "gemma") != null) return 8_192;
        return 128_000;
    }
    if (std.mem.eql(u8, provider, "deepseek")) return 64_000;
    return 200_000;
}

fn qualityModelForProvider(provider: []const u8) []const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return "claude-opus-4-6";
    if (std.mem.eql(u8, provider, "openai")) return "gpt-4.1";
    if (std.mem.eql(u8, provider, "gemini")) return "gemini-2.5-pro";
    if (std.mem.eql(u8, provider, "groq")) return "llama-3.3-70b-versatile";
    if (std.mem.eql(u8, provider, "deepseek")) return "deepseek-reasoner";
    return "claude-opus-4-6";
}

// --- /config command ---

fn handleConfigCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const args_raw = if (command.len > "/config".len) command["/config".len..] else "";
    const args = std.mem.trim(u8, args_raw, " \t");

    // /config -- show all
    if (args.len == 0) {
        return @as(?[]u8, try runtime.cfg.renderAll(allocator));
    }

    // /config set <key> <value>
    if (std.mem.startsWith(u8, args, "set ")) {
        const rest = std.mem.trim(u8, args["set ".len..], " \t");
        const ht = splitHeadTail(rest);
        if (ht.head.len == 0) {
            return @as(?[]u8, try allocator.dupe(u8, "usage: /config set <key> <value>"));
        }
        if (ht.tail.len == 0) {
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "usage: /config set {s} <value>", .{ht.head}));
        }
        // Mutate the live config. Note: cfg is *const Config in the runtime,
        // but we cast to mutable for interactive overrides -- same pattern
        // used by /lang which directly mutates runtime.preferred_language.
        const mutable_cfg: *config_mod.Config = @constCast(runtime.cfg);
        config_parse.applyKeyValue(allocator, mutable_cfg, ht.head, ht.tail) catch |err| switch (err) {
            error.UnknownConfigKey => return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "unknown config key: {s}\n\nRun /config to see all available keys.",
                .{ht.head},
            )),
            else => return @as(?[]u8, try std.fmt.allocPrint(
                allocator,
                "invalid value for {s}: {s}",
                .{ ht.head, @errorName(err) },
            )),
        };
        return @as(?[]u8, try std.fmt.allocPrint(
            allocator,
            "{s} = {s}\n(session-only; add to ~/.zcode/config.toml to persist)",
            .{ ht.head, ht.tail },
        ));
    }

    // /config <key> -- show one
    if (runtime.cfg.getFieldValue(allocator, args)) |maybe_val| {
        if (maybe_val) |val| {
            defer allocator.free(val);
            return @as(?[]u8, try std.fmt.allocPrint(allocator, "{s} = {s}", .{ args, val }));
        }
    } else |_| {}

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "unknown config key: {s}\n\nRun /config to see all available keys.",
        .{args},
    ));
}

// --- /context command ---

fn handlePromptInspectCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime, command: []const u8) !?[]u8 {
    const prefix = "/prompt inspect";
    if (!std.mem.eql(u8, command, prefix) and !std.mem.startsWith(u8, command, prefix ++ " ")) {
        return @as(?[]u8, try allocator.dupe(u8, "usage: /prompt inspect [--json] [--summary] [--no-packets] [prompt]\nRenders the next prompt packet with token/context diagnostics."));
    }

    var args = std.mem.trim(u8, command[prefix.len..], " \t");
    var json = false;
    var summary = false;
    var include_prompt_packets = true;
    while (args.len > 0) {
        if (std.mem.eql(u8, args, "--json") or std.mem.startsWith(u8, args, "--json ")) {
            json = true;
            args = std.mem.trim(u8, args["--json".len..], " \t");
            continue;
        }
        if (std.mem.eql(u8, args, "--summary") or std.mem.startsWith(u8, args, "--summary ")) {
            summary = true;
            include_prompt_packets = false;
            args = std.mem.trim(u8, args["--summary".len..], " \t");
            continue;
        }
        if (std.mem.eql(u8, args, "--no-packets") or std.mem.startsWith(u8, args, "--no-packets ")) {
            include_prompt_packets = false;
            args = std.mem.trim(u8, args["--no-packets".len..], " \t");
            continue;
        }
        break;
    }
    return @as(?[]u8, try runtime.inspectPromptWithOptions(args, .{
        .json = json,
        .summary = summary,
        .include_prompt_packets = include_prompt_packets and !summary,
    }));
}

fn handleContextCommand(allocator: std.mem.Allocator, runtime: *AgentRuntime) !?[]u8 {
    _ = allocator;
    return @as(?[]u8, try runtime.promptContextReport("(context diagnostic probe)"));
}

// --- Tests ---

const testing = std.testing;

test "applyPermissionModeCycle wires override and strips/restores dangerous rules (P3 wire)" {
    // P3 (PRD #534): proves the REPL->runtime wire. applyPermissionModeCycle is
    // exactly what the `__set_permission_mode` dispatch arm calls on the runtime's
    // fields. Cycling to plan must (1) set the override the gate reads AND (2)
    // run the transition that strips dangerous Bash allow rules; cycling back out
    // restores them.
    var store = permission_rules_mod.Store.init(testing.allocator);
    defer store.deinit();
    var stash: ?[]permission_rules_mod.Rule = null;
    defer if (stash) |s| {
        store.restoreStashed(s) catch {};
        stash = null;
    };
    var override: ?permission_decision_mod.Mode = null;

    try store.addRule(.allow, .global, "Bash", "*", "rules.tsv", 1, "user");
    try store.addRule(.allow, .global, "Read", "", "rules.tsv", 2, "user");

    // Enter plan: override flips to .plan and the dangerous Bash(*) allow is
    // stripped, so a python bash call is no longer auto-allowed under plan.
    try applyPermissionModeCycle(testing.allocator, &override, &store, &stash, "plan");
    try testing.expectEqual(permission_decision_mod.Mode.plan, override.?);
    try testing.expect(stash != null);
    try testing.expectEqual(@as(usize, 1), stash.?.len);
    try testing.expect(store.decide("/repo", "Bash", "{\"command\":\"python -c x\"}") == null);

    // Leave plan (cycle to default): override flips back and the rule is restored.
    try applyPermissionModeCycle(testing.allocator, &override, &store, &stash, "default");
    try testing.expectEqual(permission_decision_mod.Mode.default, override.?);
    try testing.expect(stash == null);
    try testing.expectEqual(
        permission_rules_mod.Action.allow,
        store.decide("/repo", "Bash", "{\"command\":\"python -c x\"}").?.action,
    );
}

test "permissions explain renders the structured rule-reason taxonomy" {
    // Smoke test of the rule-string + reason rendering the /permissions explain
    // path uses (permissions-14). Builds a store, matches, and runs the same
    // formatting without standing up a full AgentRuntime.
    var store = permission_rules_mod.Store.init(testing.allocator);
    defer store.deinit();
    try store.addRule(.deny, .global, "Bash", "curl", "", 0, "user");

    const matched = store.match("/repo", "Bash", "curl evil.com") orelse return error.TestExpectedMatch;

    const rule_string = try permission_rule_string_mod.toString(testing.allocator, .{
        .tool_name = matched.rule.tool,
        .rule_content = if (matched.rule.args_contains.len > 0) matched.rule.args_contains else null,
    });
    defer testing.allocator.free(rule_string);

    const reason_msg = try permission_reason_mod.format(testing.allocator, "Bash", .{ .rule = .{
        .rule_string = rule_string,
        .source = matched.rule.source_label,
    } });
    defer testing.allocator.free(reason_msg);

    try testing.expect(std.mem.indexOf(u8, reason_msg, "Bash(curl)") != null);
    try testing.expect(std.mem.indexOf(u8, reason_msg, "user") != null);
    try testing.expect(std.mem.indexOf(u8, reason_msg, "requires approval") != null);
}

test "configured model token matcher handles provider prefixes and ctx suffix" {
    const raw = "kimi-k2.5,deepseek/deepseek-chat:64000,local/qwen2.5-coder:32768";
    try testing.expect(configuredModelTokenExists(raw, "deepseek/deepseek-chat"));
    try testing.expect(configuredModelTokenExists(raw, "local/qwen2.5-coder"));
    try testing.expect(!configuredModelTokenExists(raw, "deepseek/deepseek-reasoner"));
}

test "known provider helper recognizes deepseek and local" {
    try testing.expect(isKnownProviderName("deepseek"));
    try testing.expect(isKnownProviderName("local"));
    try testing.expect(!isKnownProviderName("not-a-provider"));
}

test "switchReplModel resolves the opus alias to the concrete id it stores" {
    // switchReplModel runs the requested string through model_alias.resolve
    // before catalog validation and stores resolved.model as active_model.
    // A full AgentRuntime switch is not hermetic (provider adapters + disk
    // persistence), so we assert the exact resolution the switch path applies.
    const r = try model_alias.resolve(testing.allocator, "opus");
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-opus-4-6", r.model);

    const s = try model_alias.resolve(testing.allocator, "sonnet[1m]");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-sonnet-4-6[1m]", s.model);
    try testing.expect(s.one_m);
}

test "switchReplModel allowlist gate refuses a disallowed model" {
    // switchReplModel calls model_allowlist.isAllowed(resolved, available_models)
    // and returns a refusal message (active model unchanged) when it is false.
    // A full AgentRuntime switch is not hermetic, so we assert the exact gate
    // decision the switch path applies, mirroring the resolution test above.

    // available_models = "opus": /model sonnet resolves to claude-sonnet-4-6,
    // which is denied; /model opus resolves to claude-opus-4-6, which is allowed.
    const sonnet_resolved = try model_alias.resolve(testing.allocator, "sonnet");
    defer sonnet_resolved.deinit(testing.allocator);
    try testing.expect(!try model_allowlist.isAllowed(
        testing.allocator,
        sonnet_resolved.model,
        "opus",
    ));

    const opus_resolved = try model_alias.resolve(testing.allocator, "opus");
    defer opus_resolved.deinit(testing.allocator);
    try testing.expect(try model_allowlist.isAllowed(
        testing.allocator,
        opus_resolved.model,
        "opus",
    ));

    // Unset allowlist: any model passes the gate.
    try testing.expect(try model_allowlist.isAllowed(
        testing.allocator,
        sonnet_resolved.model,
        "",
    ));
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "resolveContextWindowForModel: [1m] suffix yields 1,000,000" {
    const catalog = [_]ModelCatalogItem{
        .{ .id = @constCast("claude-sonnet-4-6"), .context_window = 200_000 },
    };
    // The [1m] suffix wins over the catalog entry's 200k default.
    const w = resolveContextWindowForModel("claude-sonnet-4-6[1m]", &catalog, 200_000);
    try testing.expectEqual(@as(usize, 1_000_000), w);
}

test "resolveContextWindowForModel: no suffix uses catalog window" {
    const catalog = [_]ModelCatalogItem{
        .{ .id = @constCast("claude-sonnet-4-6"), .context_window = 200_000 },
    };
    const w = resolveContextWindowForModel("claude-sonnet-4-6", &catalog, 999);
    try testing.expectEqual(@as(usize, 200_000), w);
}

test "resolveContextWindowForModel: CLAUDE_CODE_DISABLE_1M_CONTEXT falls back to catalog" {
    _ = setenv("CLAUDE_CODE_DISABLE_1M_CONTEXT", "1", 1);
    defer _ = unsetenv("CLAUDE_CODE_DISABLE_1M_CONTEXT");

    const catalog = [_]ModelCatalogItem{
        .{ .id = @constCast("claude-sonnet-4-6[1m]"), .context_window = 200_000 },
    };
    // With the disable switch truthy, has1mContext returns false, so the [1m]
    // override is skipped and the catalog window (matched on the full id) wins.
    const w = resolveContextWindowForModel("claude-sonnet-4-6[1m]", &catalog, 999);
    try testing.expectEqual(@as(usize, 200_000), w);
}

test "derivePrReviewState maps gh pr view fields to labels" {
    // Draft PRs always show as draft regardless of reviewDecision.
    try testing.expectEqualStrings("draft", derivePrReviewState(true, ""));
    try testing.expectEqualStrings("draft", derivePrReviewState(true, "APPROVED"));
    try testing.expectEqualStrings("draft", derivePrReviewState(true, "CHANGES_REQUESTED"));

    // Non-draft: map each reviewDecision to its label.
    try testing.expectEqualStrings("approved", derivePrReviewState(false, "APPROVED"));
    try testing.expectEqualStrings("changes_requested", derivePrReviewState(false, "CHANGES_REQUESTED"));
    try testing.expectEqualStrings("pending", derivePrReviewState(false, "REVIEW_REQUIRED"));
    try testing.expectEqualStrings("pending", derivePrReviewState(false, ""));
    try testing.expectEqualStrings("pending", derivePrReviewState(false, "UNKNOWN_VALUE"));
}

test "renderRecentErrors empty ring shows fallback help text" {
    const error_log = @import("core/error_log.zig");
    error_log.resetForTesting();
    defer error_log.resetForTesting();

    const out = try renderRecentErrors(testing.allocator, 25);
    defer testing.allocator.free(out);
    // Should explain how the ring works rather than printing a
    // misleading empty result.
    try testing.expect(std.mem.indexOf(u8, out, "no errors recorded") != null);
    try testing.expect(std.mem.indexOf(u8, out, "/errors clear") != null);
}

test "renderRecentErrors with a single recorded entry shows it" {
    const error_log = @import("core/error_log.zig");
    error_log.resetForTesting();
    defer error_log.resetForTesting();

    try error_log.record(testing.allocator, "control-plane audit sync failed: NetworkUnreachable");

    const out = try renderRecentErrors(testing.allocator, 25);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Recent errors") != null);
    try testing.expect(std.mem.indexOf(u8, out, "control-plane audit sync failed") != null);
    try testing.expect(std.mem.indexOf(u8, out, "NetworkUnreachable") != null);
}

test "renderRecentErrors caps long messages with ellipsis" {
    const error_log = @import("core/error_log.zig");
    error_log.resetForTesting();
    defer error_log.resetForTesting();

    // 400-char message; the renderer caps at 320 chars and appends
    // an ellipsis marker.
    const long_msg = "x" ** 400;
    try error_log.record(testing.allocator, long_msg);

    const out = try renderRecentErrors(testing.allocator, 25);
    defer testing.allocator.free(out);
    // The visible body should be capped to 320 chars of x.
    try testing.expect(std.mem.indexOf(u8, out, "x" ** 320) != null);
    try testing.expect(std.mem.indexOf(u8, out, "x" ** 321) == null);
    // And the ellipsis marker should appear.
    try testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa6") != null);
}

test "renderRecentErrors honors max parameter" {
    const error_log = @import("core/error_log.zig");
    error_log.resetForTesting();
    defer error_log.resetForTesting();

    try error_log.record(testing.allocator, "error A");
    try error_log.record(testing.allocator, "error B");
    try error_log.record(testing.allocator, "error C");

    // Max 2 -> only the last two appear in the output.
    const out = try renderRecentErrors(testing.allocator, 2);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "error A") == null);
    try testing.expect(std.mem.indexOf(u8, out, "error B") != null);
    try testing.expect(std.mem.indexOf(u8, out, "error C") != null);
}

/// Render a condensed summary of the current session. Distinct from
/// /compact which rewrites history to reclaim context; /summary
/// reads the current history and snapshot and emits an overview
/// without mutating anything. Ported from claude-code-main/src/
/// commands/summary.
fn renderSessionSummary(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    try w.print("session id   : {s}\n", .{runtime.session_id});
    try w.print("turns        : {d}\n", .{runtime.history.len()});
    try w.print("provider     : {s}/{s}\n", .{ runtime.active_provider, runtime.active_model });
    if (runtime.active_agent) |agent| {
        try w.print("active agent : {s}\n", .{agent.name});
    }

    var user_turns: usize = 0;
    var asst_turns: usize = 0;
    var first_user: ?[]const u8 = null;
    var last_user: ?[]const u8 = null;
    for (runtime.history.view()) |turn| {
        if (turn.role == .user) {
            user_turns += 1;
            if (first_user == null) first_user = turn.content;
            last_user = turn.content;
        } else if (turn.role == .assistant) {
            asst_turns += 1;
        }
    }
    try w.print("user turns   : {d}\n", .{user_turns});
    try w.print("assist turns : {d}\n", .{asst_turns});

    if (first_user) |t| {
        try w.writeAll("\nfirst user turn:\n");
        try writeTrimmedExcerpt(w, t, 200);
    }
    if (last_user) |t| {
        if (first_user == null or t.ptr != first_user.?.ptr) {
            try w.writeAll("\n\nmost recent user turn:\n");
            try writeTrimmedExcerpt(w, t, 200);
        }
    }

    // Snapshot highlights if populated.
    const snap = &runtime.snapshot;
    if (snap.facts.len > 0) {
        try w.writeAll("\n\nfacts captured:\n");
        for (snap.facts) |f| try w.print("  - {s}\n", .{f});
    }
    if (snap.decisions.len > 0) {
        try w.writeAll("\ndecisions:\n");
        for (snap.decisions) |d| try w.print("  - {s}\n", .{d});
    }
    if (snap.open_tasks.len > 0) {
        try w.writeAll("\nopen tasks:\n");
        for (snap.open_tasks) |t| try w.print("  - {s}\n", .{t});
    }
    if (snap.file_focus.len > 0) {
        try w.writeAll("\nfile focus:\n");
        for (snap.file_focus) |f| try w.print("  - {s}\n", .{f});
    }

    try w.writeAll("\n(run /compact to fold older turns into a summary; /summary never mutates history.)");
    return out.toOwnedSlice();
}

fn writeTrimmedExcerpt(writer: anytype, text: []const u8, max_chars: usize) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len <= max_chars) {
        try writer.writeAll(trimmed);
        return;
    }
    try writer.writeAll(trimmed[0..max_chars]);
    try writer.writeAll(" ...");
}

fn renderChromeStatus(allocator: std.mem.Allocator, runtime: *AgentRuntime) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    const bridge_opt = runtime.browser;
    if (bridge_opt) |bridge| {
        const connected = bridge.isConnected();
        try w.print("chrome bridge : {s}\n", .{if (connected) "connected" else "disconnected"});
        if (connected) {
            const tools = bridge.listTools() catch |err| {
                try w.print("tools list failed: {s}\n", .{@errorName(err)});
                return out.toOwnedSlice();
            };
            defer {
                for (tools) |t| {
                    allocator.free(t.name);
                    allocator.free(t.description);
                }
                allocator.free(tools);
            }
            try w.print("tools exposed : {d}\n", .{tools.len});
            const show_n = @min(tools.len, 10);
            var i: usize = 0;
            while (i < show_n) : (i += 1) {
                try w.print("  - {s}\n", .{tools[i].name});
            }
            if (tools.len > show_n) try w.print("  ... and {d} more\n", .{tools.len - show_n});
        } else {
            try w.writeAll("install the zcode Chrome extension and run `zcode browser connect` to enable page tools.\n");
        }
    } else {
        try w.writeAll("chrome bridge not initialised in this runtime.\n");
        try w.writeAll("start zcode with the browser bridge enabled (see docs) to expose Chrome tools.\n");
    }
    return out.toOwnedSlice();
}

test "isIntervalToken accepts Ns/Nm/Nh/Nd and rejects junk" {
    try testing.expect(isIntervalToken("5m"));
    try testing.expect(isIntervalToken("30s"));
    try testing.expect(isIntervalToken("2h"));
    try testing.expect(isIntervalToken("1d"));
    try testing.expect(!isIntervalToken("m"));
    try testing.expect(!isIntervalToken("5x"));
    try testing.expect(!isIntervalToken("abc"));
    try testing.expect(!isIntervalToken(""));
}

test "intervalToCron matches the Claude Code table" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("*/5 * * * *", intervalToCron(&buf, "5m").?);
    try testing.expectEqualStrings("0 */2 * * *", intervalToCron(&buf, "120m").?); // >=60m rounds to hours
    try testing.expectEqualStrings("0 */3 * * *", intervalToCron(&buf, "3h").?);
    try testing.expectEqualStrings("0 0 */2 * *", intervalToCron(&buf, "2d").?);
    try testing.expectEqualStrings("*/1 * * * *", intervalToCron(&buf, "30s").?); // seconds round up to 1m
    try testing.expect(intervalToCron(&buf, "0m") == null);
    try testing.expect(intervalToCron(&buf, "bad") == null);
}

test "parseLoopArgs: leading token, trailing every, and default" {
    const a = parseLoopArgs("5m /babysit-prs");
    try testing.expectEqualStrings("5m", a.interval);
    try testing.expectEqualStrings("/babysit-prs", a.prompt);

    const b = parseLoopArgs("check the deploy every 20m");
    try testing.expectEqualStrings("20m", b.interval);
    try testing.expectEqualStrings("check the deploy", b.prompt);

    const c = parseLoopArgs("check the deploy");
    try testing.expectEqualStrings("10m", c.interval);
    try testing.expectEqualStrings("check the deploy", c.prompt);
}

test "parseCompactInstructions extracts the /compact focusing directive" {
    // With a trailing directive: the text is returned trimmed.
    try testing.expectEqualStrings("focus on X", parseCompactInstructions("/compact focus on X"));
    try testing.expectEqualStrings("focus on test output", parseCompactInstructions("/compact focus on test output"));
    // Surrounding whitespace is trimmed.
    try testing.expectEqualStrings("focus on X", parseCompactInstructions("/compact   focus on X  "));
    // Bare form -> empty.
    try testing.expectEqualStrings("", parseCompactInstructions("/compact"));
    // Trailing-space-only form behaves like the bare form.
    try testing.expectEqualStrings("", parseCompactInstructions("/compact "));
    try testing.expectEqualStrings("", parseCompactInstructions("/compact    "));
}

test "resolveCustomOrSkill resolves a custom command file as /<name>" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/deploy.md",
        .data = "Deploy {{args}}",
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const outcome = try resolveCustomOrSkill(allocator, cwd, "/deploy staging", "");
    switch (outcome) {
        .prompt => |prompt| {
            defer allocator.free(prompt);
            try testing.expect(std.mem.indexOf(u8, prompt, "staging") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveCustomOrSkill returns none for a genuinely unknown command" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // No commands/skills dir at all -- the name cannot resolve.
    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const outcome = try resolveCustomOrSkill(allocator, cwd, "/zzzznope", "");
    try testing.expect(outcome == .none);
}

test "resolveCustomOrSkill reports a non-user-invocable skill instead of unknown" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/skills/secret");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/skills/secret/SKILL.md",
        .data =
        \\---
        \\description: a model-only skill
        \\user-invocable: false
        \\---
        \\Do the secret thing.
        ,
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const outcome = try resolveCustomOrSkill(allocator, cwd, "/secret", "");
    switch (outcome) {
        .message => |msg| {
            defer allocator.free(msg);
            try testing.expect(std.mem.indexOf(u8, msg, "not user-invocable") != null);
            try testing.expect(std.mem.indexOf(u8, msg, "secret") != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "resolveCustomOrSkill ignores non-slash input" {
    const allocator = testing.allocator;
    const outcome = try resolveCustomOrSkill(allocator, "/nonexistent-cwd-xyz", "deploy", "");
    try testing.expect(outcome == .none);
}

test "buildStatuslinePrompt with no hint mentions status line and settings" {
    const allocator = testing.allocator;
    const prompt = try buildStatuslinePrompt(allocator, "");
    defer allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "status line") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "settings") != null);
    // The empty-hint path falls back to the reference PS1 default.
    try testing.expect(std.mem.indexOf(u8, prompt, "PS1") != null);
    // It names the settings file zcode actually uses, not ~/.claude/settings.json.
    try testing.expect(std.mem.indexOf(u8, prompt, ".zcode/settings.json") != null);
}

test "buildStatuslinePrompt includes the user-supplied hint" {
    const allocator = testing.allocator;
    const prompt = try buildStatuslinePrompt(allocator, "use a minimal git branch indicator");
    defer allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "use a minimal git branch indicator") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "status line") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "settings") != null);
}

test "buildStatuslinePrompt trims surrounding whitespace from the hint" {
    const allocator = testing.allocator;
    const prompt = try buildStatuslinePrompt(allocator, "   show the model name   ");
    defer allocator.free(prompt);

    // The trimmed hint is present, and the default PS1 fallback is NOT used.
    try testing.expect(std.mem.indexOf(u8, prompt, "show the model name") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "PS1 configuration.") == null);
}

test "renderPromptSuggestionCommands emits a TSV row for a custom command" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/deploy.md",
        .data =
        \\---
        \\description: Deploy the app
        \\argument-hint: <env>
        \\---
        \\Deploy to $env
        ,
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tsv = try renderPromptSuggestionCommandsCore(allocator, cwd);
    defer allocator.free(tsv);

    // The emitted row must use /deploy as the suggestion text and carry the
    // frontmatter description (plus the argument-hint folded into secondary).
    try testing.expect(std.mem.indexOf(u8, tsv, "command\t/deploy\t") != null);
    try testing.expect(std.mem.indexOf(u8, tsv, "Deploy the app") != null);
    try testing.expect(std.mem.indexOf(u8, tsv, "<env>") != null);
}

test "renderPromptSuggestionCommands namespaces subdirectory commands as /ns:cmd" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands/frontend");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/frontend/build.md",
        .data = "Build the frontend.",
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tsv = try renderPromptSuggestionCommandsCore(allocator, cwd);
    defer allocator.free(tsv);

    try testing.expect(std.mem.indexOf(u8, tsv, "command\t/frontend:build\t") != null);
}

test "renderPromptSuggestionCommands skips non-user-invocable commands" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/secret.md",
        .data =
        \\---
        \\description: model-only
        \\user-invocable: false
        \\---
        \\Body.
        ,
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tsv = try renderPromptSuggestionCommandsCore(allocator, cwd);
    defer allocator.free(tsv);

    try testing.expect(std.mem.indexOf(u8, tsv, "/secret") == null);
}

test "renderPromptSuggestionCommands folds explicit argument-hint into secondary" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/review.md",
        .data =
        \\---
        \\description: Review a pull request
        \\argument-hint: <pr-url>
        \\---
        \\Review $pr
        ,
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tsv = try renderPromptSuggestionCommandsCore(allocator, cwd);
    defer allocator.free(tsv);

    // Explicit argument-hint wins and is rendered after the description.
    try testing.expect(std.mem.indexOf(u8, tsv, "<pr-url>") != null);
    try testing.expect(std.mem.indexOf(u8, tsv, "Review a pull request <pr-url>") != null);
}

test "renderPromptSuggestionCommands synthesizes hint from named arguments" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, ".zcode/commands");
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = ".zcode/commands/open.md",
        .data =
        \\---
        \\description: Open a thing
        \\arguments: url mode
        \\---
        \\Open $url in $mode
        ,
    });

    const cwd = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(cwd);

    const tsv = try renderPromptSuggestionCommandsCore(allocator, cwd);
    defer allocator.free(tsv);

    // No explicit argument-hint, so the hint is `[url] [mode]` synthesized from
    // the named `arguments` slots.
    try testing.expect(std.mem.indexOf(u8, tsv, "[url]") != null);
    try testing.expect(std.mem.indexOf(u8, tsv, "[mode]") != null);
    try testing.expect(std.mem.indexOf(u8, tsv, "Open a thing [url] [mode]") != null);
}

test "suggestionArgumentHint prefers explicit hint over named args" {
    const allocator = testing.allocator;
    const names = [_][]const u8{ "url", "mode" };
    const hint = try suggestionArgumentHint(allocator, "<pr-url>", &names);
    defer allocator.free(hint);
    try testing.expectEqualStrings("<pr-url>", hint);
}

test "suggestionArgumentHint synthesizes from named args when no explicit hint" {
    const allocator = testing.allocator;
    const names = [_][]const u8{ "url", "mode" };
    const hint = try suggestionArgumentHint(allocator, "", &names);
    defer allocator.free(hint);
    try testing.expectEqualStrings("[url] [mode]", hint);
}

test "suggestionArgumentHint returns empty when no hint and no args" {
    const allocator = testing.allocator;
    const names = [_][]const u8{};
    const hint = try suggestionArgumentHint(allocator, "", &names);
    defer allocator.free(hint);
    try testing.expectEqual(@as(usize, 0), hint.len);
}

test "suggestionArgumentHint truncates a multi-line explicit hint to one line" {
    const allocator = testing.allocator;
    const names = [_][]const u8{};
    const hint = try suggestionArgumentHint(allocator, "<env>\nleaked", &names);
    defer allocator.free(hint);
    try testing.expectEqualStrings("<env>", hint);
}

// ── /rewind code-restore test support ──
//
// A minimal AgentRuntime harness so the rewind handlers can be driven
// end-to-end. The git workspace lives at `cwd`; the session store lives
// under a sibling `sessions` dir so checkpoints and the working tree do
// not share a directory.
const RewindTestHarness = struct {
    allocator: std.mem.Allocator,
    cwd: []u8,
    logs_dir: []u8,
    sessions_dir: []u8,
    registry_path: []u8,
    cfg: config_mod.Config,
    policy: policy_mod.Policy,
    audit: @import("core/logger.zig").AuditLogger,
    store: session_store_mod.Store,
    mcp: mcp_client.Client,
    runtime: AgentRuntime,

    fn init(allocator: std.mem.Allocator, root: []const u8) !*RewindTestHarness {
        const self = try allocator.create(RewindTestHarness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cwd = try std.fs.path.join(allocator, &.{ root, "workspace" });
        errdefer allocator.free(self.cwd);
        self.logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
        errdefer allocator.free(self.logs_dir);
        self.sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(self.sessions_dir);
        self.registry_path = try std.fs.path.join(allocator, &.{ root, "mcp", "registry.json" });
        errdefer allocator.free(self.registry_path);

        try @import("core/paths.zig").ensureDir(self.cwd);

        self.cfg = try config_mod.Config.init(allocator);
        errdefer self.cfg.deinit(allocator);
        self.policy = try policy_mod.Policy.init(allocator);
        errdefer self.policy.deinit();
        self.audit = try @import("core/logger.zig").AuditLogger.init(allocator, self.logs_dir);
        errdefer self.audit.deinit();
        self.store = try session_store_mod.Store.init(allocator, self.sessions_dir, false);
        errdefer self.store.deinit();
        self.mcp = try mcp_client.Client.init(allocator, self.registry_path);
        errdefer self.mcp.deinit();

        self.runtime = try AgentRuntime.init(
            allocator,
            self.cwd,
            &self.cfg,
            &self.policy,
            &self.audit,
            &self.store,
            &self.mcp,
            null,
            false,
            false,
            false,
            false,
        );
        return self;
    }

    fn deinit(self: *RewindTestHarness) void {
        self.runtime.deinit();
        self.mcp.deinit();
        self.store.deinit();
        self.audit.deinit();
        self.policy.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.registry_path);
        self.allocator.destroy(self);
    }
};

fn rewindTestRunGit(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, @import("zcode_runtime").io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!(result.term == .exited and result.term.exited == 0)) return error.CommandFailed;
}

fn rewindTestWriteFile(path: []const u8, bytes: []const u8) !void {
    const io = @import("zcode_runtime").io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn rewindTestFileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(@import("zcode_runtime").io, path, .{}) catch return false;
    return true;
}

test "/rewind code-restore reverts the working tree to the checkpoint" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    // Seed a git repo with one committed tracked file at the workspace cwd.
    const tracked = try std.fs.path.join(allocator, &.{ runtime.cwd, "tracked.txt" });
    defer allocator.free(tracked);
    try rewindTestWriteFile(tracked, "original\n");
    rewindTestRunGit(allocator, &.{ "git", "-C", runtime.cwd, "init" }) catch return error.SkipZigTest;
    try rewindTestRunGit(allocator, &.{ "git", "-C", runtime.cwd, "config", "user.email", "test@example.com" });
    try rewindTestRunGit(allocator, &.{ "git", "-C", runtime.cwd, "config", "user.name", "zcode test" });
    try rewindTestRunGit(allocator, &.{ "git", "-C", runtime.cwd, "add", "tracked.txt" });
    try rewindTestRunGit(allocator, &.{ "git", "-C", runtime.cwd, "commit", "-m", "init" });

    // Seed the conversation (both in-memory and on disk) and snapshot it.
    try runtime.history.append(runtime.session_id, .user, "do the thing");
    try runtime.history.append(runtime.session_id, .assistant, "done");
    var snapshot = session_store_mod.emptySnapshot();
    try runtime.store.appendSnapshot(runtime.session_id, &snapshot, "summary", runtime.cwd);

    // Take a checkpoint capturing this state.
    var saved = try session_bundles.saveCheckpoint(allocator, runtime.store, runtime.cwd, runtime.session_id, "before");
    defer saved.deinit(allocator);

    // Diverge the working tree: change the tracked file, add an untracked one.
    try rewindTestWriteFile(tracked, "changed\n");
    const untracked = try std.fs.path.join(allocator, &.{ runtime.cwd, "untracked.txt" });
    defer allocator.free(untracked);
    try rewindTestWriteFile(untracked, "scratch\n");

    // Run the code-and-conversation rewind path.
    const msg = try handleRewindToHistoryIndexWithCode(allocator, runtime, 0);
    defer allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "restored code and conversation") != null);

    // Tracked file reverted, untracked file removed.
    const final = try std.Io.Dir.cwd().readFileAlloc(@import("zcode_runtime").io, tracked, allocator, .limited(1024));
    defer allocator.free(final);
    try testing.expectEqualStrings("original\n", final);
    try testing.expect(!rewindTestFileExists(untracked));
}

test "/rewind conversation-only leaves the working tree untouched" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    // A sentinel file in the workspace that must survive a conversation-only
    // rewind (the default, non-destructive path).
    const sentinel = try std.fs.path.join(allocator, &.{ runtime.cwd, "keep.txt" });
    defer allocator.free(sentinel);
    try rewindTestWriteFile(sentinel, "keep me\n");

    try runtime.history.append(runtime.session_id, .user, "first prompt");
    try runtime.history.append(runtime.session_id, .assistant, "first answer");
    try runtime.history.append(runtime.session_id, .user, "second prompt");
    try runtime.history.append(runtime.session_id, .assistant, "second answer");
    try testing.expectEqual(@as(usize, 4), runtime.history.len());

    // Conversation-only rewind to before the second prompt (index 2).
    const msg = try handleRewindToHistoryIndex(allocator, runtime, 2);
    defer allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "on disk is unchanged") != null);

    // History truncated to the kept prefix; workspace file untouched.
    try testing.expectEqual(@as(usize, 2), runtime.history.len());
    const final = try std.Io.Dir.cwd().readFileAlloc(@import("zcode_runtime").io, sentinel, allocator, .limited(1024));
    defer allocator.free(final);
    try testing.expectEqualStrings("keep me\n", final);
}

test "bare /btw returns the usage string and leaves history untouched" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    try runtime.history.append(runtime.session_id, .user, "first prompt");
    try runtime.history.append(runtime.session_id, .assistant, "first answer");
    const before_mem = runtime.history.len();
    const before_disk = (try runtime.store.countTurns(runtime.session_id)).total;

    const out = try replCommandCallback(runtime, allocator, "/btw");
    try testing.expect(out != null);
    defer allocator.free(out.?);
    try testing.expect(std.mem.indexOf(u8, out.?, "Usage: /btw") != null);

    // The usage path must not mutate the conversation at all.
    try testing.expectEqual(before_mem, runtime.history.len());
    try testing.expectEqual(before_disk, (try runtime.store.countTurns(runtime.session_id)).total);
}

test "/btw side question never mutates the conversation (in-memory or on disk)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    // Seed a conversation in memory and on disk.
    try runtime.history.append(runtime.session_id, .user, "build the parser");
    try runtime.history.append(runtime.session_id, .assistant, "parser built");
    const before_mem = runtime.history.len();
    try testing.expectEqual(@as(usize, 2), before_mem);
    // On-disk size is encryption-agnostic (records may be encrypted, so a
    // "type":"turn" substring count is unreliable in this harness); the byte
    // length still grows iff something was appended, which is exactly the
    // invariant we want to pin.
    const before_disk_bytes = (try runtime.store.countTurns(runtime.session_id)).bytes;

    // Force a deterministic, network-free failure: restrict the allowlist so
    // the active model is refused BEFORE any API call (model_allowlist gate in
    // callModel). This exercises runSideQuestion's failure path without a live
    // provider, and proves the side question never appends a turn -- the whole
    // point of /btw is that it does not interrupt the main transcript.
    allocator.free(h.cfg.available_models);
    h.cfg.available_models = try allocator.dupe(u8, "definitely-not-the-active-model-xyz");

    const result = runtime.runSideQuestion("what is 2+2");
    try testing.expectError(error.ModelNotAllowed, result);

    // Neither the in-memory history nor the on-disk session JSONL grew.
    try testing.expectEqual(before_mem, runtime.history.len());
    try testing.expectEqual(before_disk_bytes, (try runtime.store.countTurns(runtime.session_id)).bytes);
}

test "handleColorPalette persists a valid color, resets it, and lists palette on invalid" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(sessions_dir);

    var store = try session_store_mod.Store.init(allocator, sessions_dir, false);
    defer store.deinit();

    const sid = "color-test-session";

    // Valid color persists to the sidecar and a fresh read returns it.
    {
        const msg = try handleColorPalette(allocator, &store, sid, "blue");
        defer allocator.free(msg);
        try testing.expectEqualStrings("Session color set to blue", msg);
        const persisted = try store.readColor(sid);
        try testing.expect(persisted != null);
        defer allocator.free(persisted.?);
        try testing.expectEqualStrings("blue", persisted.?);
    }

    // Mixed-case input is normalized to the canonical lower-cased name.
    {
        const msg = try handleColorPalette(allocator, &store, sid, "GREEN");
        defer allocator.free(msg);
        try testing.expectEqualStrings("Session color set to green", msg);
        const persisted = try store.readColor(sid);
        defer allocator.free(persisted.?);
        try testing.expectEqualStrings("green", persisted.?);
    }

    // Reset alias clears the stored color (sidecar removed -> default).
    {
        const msg = try handleColorPalette(allocator, &store, sid, "reset");
        defer allocator.free(msg);
        try testing.expectEqualStrings("Session color reset to default", msg);
        try testing.expectEqual(@as(?[]u8, null), try store.readColor(sid));
    }

    // Invalid color lists the palette CSV and does not persist anything.
    {
        const msg = try handleColorPalette(allocator, &store, sid, "notacolor");
        defer allocator.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, "red, blue, green, yellow, purple, orange, pink, cyan") != null);
        try testing.expectEqual(@as(?[]u8, null), try store.readColor(sid));
    }

    // No argument also lists the palette with the "Please provide" prefix.
    {
        const msg = try handleColorPalette(allocator, &store, sid, "");
        defer allocator.free(msg);
        try testing.expect(std.mem.startsWith(u8, msg, "Please provide a color."));
        try testing.expect(std.mem.indexOf(u8, msg, "red, blue, green, yellow, purple, orange, pink, cyan") != null);
    }
}

// commands-sweep-08: /effort persistence + CLAUDE_CODE_EFFORT_LEVEL override.
//
// These tests override HOME so persistUserConfigField writes the
// reasoning_effort key into the tmp dir's .zcode/config.toml (paths.resolve
// reads HOME via core/env.zig, which consults the override map first), and
// override CLAUDE_CODE_EFFORT_LEVEL so the env-precedence branches run without
// touching the real process environment.
const env_mod = @import("core/env.zig");

test "/effort env override wins over the requested level and is announced" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    // Make sure no stray real XDG var redirects the config path away from HOME.
    try env_mod.setOverride("XDG_CONFIG_HOME", "");
    try env_mod.setOverride(effort_level_mod.ENV_VAR, "high");

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    const out = try replCommandCallback(runtime, allocator, "/effort low");
    try testing.expect(out != null);
    defer allocator.free(out.?);

    // The message must announce the env override (env wins this session).
    try testing.expect(std.mem.indexOf(u8, out.?, effort_level_mod.ENV_VAR) != null);
    try testing.expect(std.mem.indexOf(u8, out.?, "overrides this session") != null);

    // The live runtime level resolves to the env value, NOT the requested low.
    try testing.expectEqual(types.ReasoningEffort.high, runtime.reasoning_effort);
}

test "/effort medium persists to config.toml and a fresh load reads it back" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");
    // No CLAUDE_CODE_EFFORT_LEVEL override: ensure it is unset so the persisted
    // value is what governs a fresh load.
    try env_mod.setOverride(effort_level_mod.ENV_VAR, "");

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    const out = try replCommandCallback(runtime, allocator, "/effort medium");
    try testing.expect(out != null);
    defer allocator.free(out.?);

    // No env conflict and a persistable level: no "(this session only)" suffix
    // and no env note (acceptance criterion 3).
    try testing.expect(std.mem.indexOf(u8, out.?, "Set effort level to medium") != null);
    try testing.expect(std.mem.indexOf(u8, out.?, "(this session only)") == null);
    try testing.expect(std.mem.indexOf(u8, out.?, effort_level_mod.ENV_VAR) == null);
    try testing.expectEqual(types.ReasoningEffort.medium, runtime.reasoning_effort);

    // A fresh config load from the persisted file reads "medium" back, and a
    // freshly-initialised runtime resolves its startup effort to .medium.
    const opts = @import("cli/args.zig").CliOptions{};
    var loaded = try config_parse.load(allocator, h.cwd, &opts);
    defer loaded.deinit(allocator);
    try testing.expectEqualStrings("medium", loaded.config.reasoning_effort);
    try testing.expectEqual(types.ReasoningEffort.medium, effort_level_mod.resolveStartup(loaded.config.reasoning_effort));
}

test "/effort auto reports session-only and clears the persisted override" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try @import("core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    defer env_mod.clearOverrides();
    try env_mod.setOverride("HOME", root);
    try env_mod.setOverride("XDG_CONFIG_HOME", "");
    try env_mod.setOverride(effort_level_mod.ENV_VAR, "");

    var h = try RewindTestHarness.init(allocator, root);
    defer h.deinit();
    const runtime = &h.runtime;

    // First persist a concrete level, then switch back to auto.
    {
        const out = try replCommandCallback(runtime, allocator, "/effort high");
        try testing.expect(out != null);
        allocator.free(out.?);
    }
    const out = try replCommandCallback(runtime, allocator, "/effort auto");
    try testing.expect(out != null);
    defer allocator.free(out.?);

    // auto is session-only -> the suffix is present, no env note.
    try testing.expect(std.mem.indexOf(u8, out.?, "(this session only)") != null);
    try testing.expectEqual(types.ReasoningEffort.auto, runtime.reasoning_effort);

    // A fresh load reads "auto" back: the persisted override was cleared.
    const opts = @import("cli/args.zig").CliOptions{};
    var loaded = try config_parse.load(allocator, h.cwd, &opts);
    defer loaded.deinit(allocator);
    try testing.expectEqualStrings("auto", loaded.config.reasoning_effort);
}
