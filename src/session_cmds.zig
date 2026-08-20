const std = @import("std");
const rng = @import("core/rng.zig");
const rt = @import("zcode_runtime");
const clock = @import("core/clock.zig");
const std_io = @import("core/std_io.zig");
const display_safe = @import("core/display_safe.zig");
const egress = @import("core/egress.zig");

const config_mod = @import("core/config.zig");
const agents_mod = @import("core/agents.zig");
const commands_mod = @import("core/commands.zig");
const hooks_mod = @import("core/hooks.zig");
const logger_mod = @import("core/logger.zig");
const marketplace_mod = @import("core/marketplace.zig");
const plugins_mod = @import("core/plugins.zig");
const plugin_settings_mod = @import("core/plugin_settings.zig");
const plugin_policy_mod = @import("core/plugin_policy.zig");
const paths_mod = @import("core/paths.zig");
const security_mod = @import("core/security.zig");
const skills_mod = @import("core/skills.zig");
const trust_mod = @import("core/trust.zig");
const types = @import("core/types.zig");
const compaction = @import("core/compaction.zig");
const policy_mod = @import("policy/policy.zig");
const session_store = @import("session/store.zig");
const session_search = @import("core/session_search.zig");
const session_bundles = @import("session/bundles.zig");
const mcp_client = @import("mcp/client.zig");
const browser_bridge_mod = @import("mcp/browser_bridge.zig");
const agent_runtime = @import("agent_runtime.zig");
const review_flow = @import("review_flow.zig");
const remote_daemon = @import("remote_daemon.zig");
const session_mgmt = @import("session_mgmt.zig");
const format_mod = @import("core/format.zig");
const coordinator_mode = @import("core/coordinator_mode.zig");

// --- Session lifecycle commands ---

pub fn cmdSessionList(allocator: std.mem.Allocator, store: *session_store.Store, writer: anytype) !void {
    const sessions = try store.list();
    defer store.freeSessionEntries(sessions);

    if (sessions.len == 0) {
        try writer.writeAll("no sessions\n");
        return;
    }

    // Replace the raw "updated=<unix_ts>" dump with a human-readable
    // "updated Mon 13:30 (3h ago)" label. The absolute time comes from
    // formatBriefTimestamp (pass 105); the relative hint in parens
    // comes from formatRelativeTimeShort (pass 109). The pair gives
    // users both "when exactly" and "how fresh" at a glance without
    // forcing them to mentally decode a Unix timestamp.
    //
    // When the session has a human-readable label (set via /rename
    // and persisted as a sidecar file since pass 116), the label is
    // printed after the id so `/session list` becomes scannable
    // without having to remember nanosecond IDs.
    const now_ts: i64 = @intCast(clock.nowSeconds());
    for (sessions) |entry| {
        var label_buf: [32]u8 = undefined;
        var rel_buf: [32]u8 = undefined;
        const time_label = format_mod.formatBriefTimestamp(&label_buf, entry.updated_ts, now_ts);
        const rel = format_mod.formatRelativeTimeShort(&rel_buf, entry.updated_ts, now_ts);
        // Title precedence (Phase 11 sessions-06): a user-set label (via
        // /rename) always wins; otherwise the AI-generated title; otherwise
        // no title column. The AI title is a best-effort sidecar that may be
        // absent (offline / pre-feature sessions), so the read is swallowed.
        var ai_title_owned: ?[]u8 = null;
        defer if (ai_title_owned) |t| allocator.free(t);
        const raw_user_label = entry.label orelse blk: {
            ai_title_owned = store.readAiTitle(entry.id) catch null;
            break :blk ai_title_owned orelse "";
        };
        // Session titles are user-supplied via /rename or model-generated and
        // persisted in a sidecar file -- a hostile sidecar (or a plain typo
        // with a stray newline) used to corrupt the TSV row layout.
        const safe_user_label = try display_safe.sanitize(allocator, raw_user_label);
        defer allocator.free(safe_user_label);
        const user_label: []const u8 = safe_user_label;
        // Phase 11 sessions-07: per-session git branch, persisted as a sidecar
        // at session start. Sanitized before TSV display so a stray newline in
        // a branch name cannot corrupt the row layout. Absent for non-repo /
        // pre-feature sessions.
        const branch_raw = store.readBranch(entry.id) catch null;
        defer if (branch_raw) |b| allocator.free(b);
        var branch_safe_owned: ?[]u8 = null;
        defer if (branch_safe_owned) |b| allocator.free(b);
        const branch: []const u8 = if (branch_raw) |b| blk: {
            branch_safe_owned = try display_safe.sanitize(allocator, b);
            break :blk branch_safe_owned.?;
        } else "";
        if (user_label.len > 0) {
            if (time_label.len > 0 and rel.len > 0) {
                try writer.print("{s}\t{s}\tupdated={s} ({s})", .{ entry.id, user_label, time_label, rel });
            } else {
                try writer.print("{s}\t{s}\tupdated={d}", .{ entry.id, user_label, entry.updated_ts });
            }
        } else if (time_label.len > 0 and rel.len > 0) {
            try writer.print("{s}\tupdated={s} ({s})", .{ entry.id, time_label, rel });
        } else if (time_label.len > 0) {
            try writer.print("{s}\tupdated={s}", .{ entry.id, time_label });
        } else {
            try writer.print("{s}\tupdated={d}", .{ entry.id, entry.updated_ts });
        }
        if (branch.len > 0) {
            try writer.print("\tbranch={s}", .{branch});
        }
        try writer.writeAll("\n");
    }
}

pub fn cmdSessionResume(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    subject: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    // No argument: print the session list with a resume hint. The CLI does
    // not host the interactive picker (that lives in the REPL); listing the
    // ids is the most useful no-arg behavior here.
    const arg = subject orelse {
        try cmdSessionList(allocator, store, writer);
        try writer.writeAll("\nUse `zcode session resume <id-or-term>` to resume one.\n");
        return;
    };

    // Resolve the argument to a concrete session id: exact id first (the
    // historical fast path), then fuzzy by id/label. `resolved_owned` holds
    // the id when it came from fuzzy resolution (it must outlive the call).
    var resolved_owned: ?[]u8 = null;
    defer if (resolved_owned) |r| allocator.free(r);
    const session_id: []const u8 = blk: {
        // Exact-id fast path: a valid, existing session file resumes directly.
        if (store.sessionPath(arg)) |p| {
            defer allocator.free(p);
            const exists = if (std.Io.Dir.cwd().access(rt.io, p, .{})) |_| true else |_| false;
            if (exists) break :blk arg;
        } else |_| {}

        // Fuzzy fallback over the session list (id + label).
        const entries = try store.list();
        defer store.freeSessionEntries(entries);

        const candidates = try allocator.alloc(session_search.Candidate, entries.len);
        defer allocator.free(candidates);
        for (entries, 0..) |e, i| {
            candidates[i] = .{ .id = e.id, .label = e.label orelse "" };
        }

        const target = try session_search.resolveResumeTarget(allocator, candidates, arg);
        switch (target) {
            .exact, .single => |id| {
                resolved_owned = try allocator.dupe(u8, id);
                break :blk resolved_owned.?;
            },
            .multiple => |ids| {
                defer allocator.free(ids);
                const stderr = std_io.stderrWriter();
                try stderr.print("error: session resume: multiple sessions match '{s}':\n", .{arg});
                for (ids) |id| {
                    var matched_label: []const u8 = "";
                    for (entries) |e| {
                        if (std.mem.eql(u8, e.id, id)) {
                            matched_label = e.label orelse "";
                            break;
                        }
                    }
                    if (matched_label.len > 0) {
                        try stderr.print("      {s}  {s}\n", .{ id, matched_label });
                    } else {
                        try stderr.print("      {s}\n", .{id});
                    }
                }
                try stderr.writeAll("  - Re-run with a full session id to pick one.\n");
                return error.SessionNotFound;
            },
            .none => {
                const stderr = std_io.stderrWriter();
                const display = try formatDisplaySessionId(allocator, arg);
                defer allocator.free(display);
                try stderr.print("error: session resume: no such session '{s}'.\n", .{display});
                const n = @min(entries.len, 3);
                if (n > 0) {
                    try stderr.writeAll("  - Most recent sessions:\n");
                    for (entries[0..n]) |e| {
                        try stderr.print("      {s}\n", .{e.id});
                    }
                    try stderr.writeAll("  - Or run `zcode session list` for the full list.\n");
                } else {
                    try stderr.writeAll("  - You have no saved sessions yet; run `zcode` to start one.\n");
                }
                return error.SessionNotFound;
            },
        }
    };

    try writer.print("resumed session {s}\n", .{session_id});

    // Coordinator-mode reconciliation (remote-server-01): if the session was
    // saved running in a different mode than the live env gate, flip the env to
    // match the resumed session and surface a one-line warning. A missing
    // sidecar (pre-feature / never-coordinator session) reconciles to "normal".
    {
        const stored_mode = store.readMode(session_id) catch null;
        defer if (stored_mode) |m| allocator.free(m);
        const stored = stored_mode orelse coordinator_mode.MODE_NORMAL;
        if (coordinator_mode.matchSessionMode(stored)) |warning| {
            try writer.print("{s}\n", .{warning});
        }
    }

    return session_mgmt.resumeSessionInteractive(allocator, cwd, cfg, policy, audit, store, mcp, browser, session_id, null, writer, auto_approve_high, strict, yolo_mode, initial_agent);
}

pub fn cmdSessionContinue(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    initial_prompt: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    const sessions = try store.list();
    defer store.freeSessionEntries(sessions);

    if (sessions.len == 0) {
        try writer.writeAll("no previous sessions, starting new session\n");
        return session_mgmt.runInteractive(allocator, cwd, cfg, policy, audit, store, mcp, browser, auto_approve_high, strict, yolo_mode, initial_prompt, initial_agent, null);
    }

    const latest_id = sessions[0].id;
    try writer.print("resuming session {s}\n", .{latest_id});
    return session_mgmt.resumeSessionInteractive(allocator, cwd, cfg, policy, audit, store, mcp, browser, latest_id, initial_prompt, writer, auto_approve_high, strict, yolo_mode, initial_agent);
}

/// Render `session_id` for display in an error message. Replaces
/// control characters (incl. '\n'/'\t') with their `\xHH` escapes
/// so a user's bogus id containing a newline does not rewrap the
/// terminal output across lines, and truncates very long ids with
/// an `...(NNN chars)` tail so the message stays on one readable
/// line. Caller owns the returned slice.
fn formatDisplaySessionId(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    const max_visible = 60;
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const visible = @min(session_id.len, max_visible);
    for (session_id[0..visible]) |b| {
        if (b < 0x20 or b == 0x7f) {
            try out.writer().print("\\x{x:0>2}", .{b});
        } else {
            try out.append(b);
        }
    }
    if (session_id.len > max_visible) {
        try out.writer().print("...({d} chars total)", .{session_id.len});
    }
    return out.toOwnedSlice();
}

/// Shared early-validation for every session-by-id command. Rejects an
/// invalid or missing session id before the handler starts allocating
/// work, so a typo produces a clean "no such session '...'" line on
/// stderr instead of bubbling up `error: FileNotFound (provider=...,
/// model=...)` from load() deep in the stack. On success the caller
/// owns the returned absolute path and must `allocator.free(...)` it.
pub fn assertSessionExists(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    session_id: []const u8,
    cmd_name: []const u8,
) ![]u8 {
    const path = store.sessionPath(session_id) catch |err| {
        const stderr = std_io.stderrWriter();
        const display = try formatDisplaySessionId(allocator, session_id);
        defer allocator.free(display);
        try stderr.print(
            "error: {s}: invalid session id '{s}': {s}\n  - Run `zcode session list` for valid IDs.\n",
            .{ cmd_name, display, @errorName(err) },
        );
        return error.InvalidSessionId;
    };
    errdefer allocator.free(path);
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const stderr = std_io.stderrWriter();
            const display = try formatDisplaySessionId(allocator, session_id);
            defer allocator.free(display);
            try stderr.print(
                "error: {s}: no such session '{s}'.\n  - Run `zcode session list` to see available IDs.\n",
                .{ cmd_name, display },
            );
            return error.SessionNotFound;
        },
        else => return err,
    };
    return path;
}

pub fn cmdSessionCompact(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
    store: *session_store.Store,
    subject: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const path = try assertSessionExists(allocator, store, session_id, "session compact");
    allocator.free(path);

    var loaded = try store.load(session_id);
    defer loaded.deinit(allocator);

    const budget = types.BudgetPlan.init(
        cfg.model_context_window,
        cfg.reserved_output_tokens,
        cfg.reserved_reasoning_tokens,
    );

    var result = try compaction.maybeCompact(allocator, loaded.history, budget, null, "");
    defer result.deinit(allocator);

    if (!result.did_compact) {
        try writer.print("session {s} does not require compaction\n", .{session_id});
        return;
    }

    // CLI compaction re-snapshots an existing session; no live cwd to
    // record, so pass "" for the origin breadcrumb (sessions-04).
    try store.appendSnapshot(session_id, &result.snapshot, result.conversation_summary, "");
    try writer.print("session {s} compacted hash={x}\n", .{ session_id, result.summary_hash });
}

pub fn cmdSessionExport(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    markdown: bool,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session export");
    allocator.free(vpath);

    var loaded = try store.load(session_id);
    defer loaded.deinit(allocator);

    if (markdown) {
        const session_export_md = @import("core/session_export_md.zig");
        // Prefer the first user prompt as the document title (sessions-05),
        // falling back to the session id when there is no prompt.
        var title: []const u8 = if (loaded.id.len > 0) loaded.id else "session";
        for (loaded.history) |turn| {
            if (turn.role == .user) {
                const trimmed = std.mem.trim(u8, turn.content, " \t\r\n");
                if (trimmed.len > 0) title = trimmed;
                break;
            }
        }
        const md = try session_export_md.toMarkdown(allocator, title, loaded.history);
        defer allocator.free(md);
        try writer.print("{s}\n", .{md});
        return;
    }

    const JsonTurn = struct {
        role: []const u8,
        content: []const u8,
        timestamp: i64,
    };

    const turns = try allocator.alloc(JsonTurn, loaded.history.len);
    defer allocator.free(turns);

    for (loaded.history, 0..) |turn, idx| {
        turns[idx] = .{
            .role = types.roleToString(turn.role),
            .content = turn.content,
            .timestamp = turn.timestamp,
        };
    }

    try writer.print("{f}\n", .{std.json.fmt(.{
        .session_id = loaded.id,
        .conversation_summary = loaded.conversation_summary,
        .history = turns,
        .snapshot = .{
            .facts = loaded.snapshot.facts,
            .decisions = loaded.snapshot.decisions,
            .open_tasks = loaded.snapshot.open_tasks,
            .file_focus = loaded.snapshot.file_focus,
            .recent_tool_outcomes = loaded.snapshot.recent_tool_outcomes,
            .handoff_summary = loaded.snapshot.handoff_summary,
        },
    }, .{})});
}

pub fn cmdSessionCheckpoint(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    store: *session_store.Store,
    subject: ?[]const u8,
    label: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;

    // Verify the session exists before we start allocating a
    // checkpoint bundle. A missing ID used to surface as an opaque
    // "error: FileNotFound" from saveCheckpoint deep in the tree;
    // name the ID up front and point at `session list`.
    const path = store.sessionPath(session_id) catch |err| {
        const stderr = std_io.stderrWriter();
        const display = try formatDisplaySessionId(allocator, session_id);
        defer allocator.free(display);
        try stderr.print(
            "error: session checkpoint: invalid session id '{s}': {s}\n  - Run `zcode session list` for valid IDs.\n",
            .{ display, @errorName(err) },
        );
        return error.InvalidSessionId;
    };
    defer allocator.free(path);
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const stderr = std_io.stderrWriter();
            const display = try formatDisplaySessionId(allocator, session_id);
            defer allocator.free(display);
            try stderr.print(
                "error: session checkpoint: no such session '{s}'.\n  - Run `zcode session list` to see available IDs.\n",
                .{display},
            );
            return error.SessionNotFound;
        }
        return err;
    };

    var saved = try session_bundles.saveCheckpoint(allocator, store, cwd, session_id, label);
    defer saved.deinit(allocator);
    const safe_label = try display_safe.sanitize(allocator, saved.label);
    defer allocator.free(safe_label);
    try writer.print("checkpoint saved\tid={s}\tlabel={s}\tpath={s}\n", .{ saved.id, safe_label, saved.path });
}

pub fn cmdSessionCheckpoints(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session checkpoints");
    allocator.free(vpath);
    const checkpoints = try session_bundles.listCheckpointsForStore(allocator, store, session_id);
    defer session_bundles.freeCheckpointEntries(allocator, checkpoints);

    if (checkpoints.len == 0) {
        try writer.print("no checkpoints for {s}\n", .{session_id});
        return;
    }

    for (checkpoints) |entry| {
        const safe_label = try display_safe.sanitize(allocator, entry.label);
        defer allocator.free(safe_label);
        try writer.print("{s}\tlabel={s}\tcreated={d}\tpath={s}\n", .{ entry.id, safe_label, entry.created_ts, entry.path });
    }
}

pub fn cmdSessionShare(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    label: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session share");
    allocator.free(vpath);
    var saved = try session_bundles.shareSession(allocator, store, session_id, label);
    defer saved.deinit(allocator);
    const safe_label = try display_safe.sanitize(allocator, saved.label);
    defer allocator.free(safe_label);
    try writer.print("share bundle saved\tid={s}\tlabel={s}\tpath={s}\n", .{ saved.id, safe_label, saved.path });
}

pub fn cmdSessionImport(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    writer: anytype,
) !void {
    const bundle_ref = subject orelse {
        const stderr = std_io.stderrWriter();
        try stderr.writeAll(
            "error: session import: missing bundle reference.\n" ++
                "  Usage: zcode session import <path-to-bundle.json>\n" ++
                "         zcode session import <https://share-url>\n",
        );
        return error.MissingSessionId;
    };

    // For local file references (not URLs), verify the file exists
    // before we kick off the import pipeline. A typo or wrong cwd
    // otherwise surfaces as an opaque "error: FileNotFound" deep in
    // session_bundles. Print a targeted message naming the path.
    if (!isRemoteBundleRef(bundle_ref)) {
        const stat = std.Io.Dir.cwd().statFile(rt.io, bundle_ref, .{}) catch |err| {
            const stderr = std_io.stderrWriter();
            switch (err) {
                error.FileNotFound => try stderr.print(
                    "error: session import: no such file: {s}\n",
                    .{bundle_ref},
                ),
                error.AccessDenied => try stderr.print(
                    "error: session import: permission denied reading {s}\n",
                    .{bundle_ref},
                ),
                else => try stderr.print(
                    "error: session import: cannot read {s} ({s}).\n",
                    .{ bundle_ref, @errorName(err) },
                ),
            }
            return error.BundleReadFailed;
        };
        if (stat.kind == .directory) {
            const stderr = std_io.stderrWriter();
            try stderr.print(
                "error: session import: path is a directory, expected a bundle file: {s}\n",
                .{bundle_ref},
            );
            return error.BundleReadFailed;
        }
    }

    const session_id = (if (isRemoteBundleRef(bundle_ref)) blk: {
        const temp_path = try writeTempBundle(allocator, bundle_ref);
        defer allocator.free(temp_path);
        defer std.Io.Dir.cwd().deleteFile(rt.io, temp_path) catch {};
        break :blk session_bundles.importBundleFile(allocator, store, temp_path);
    } else session_bundles.importBundleFile(allocator, store, bundle_ref)) catch |err| {
        // Distinguish JSON-parse failures from schema-shape failures
        // so the user gets an actionable message instead of the
        // generic "error: SyntaxError". Everything below is a user
        // error (bad file), not an internal bug.
        const stderr = std_io.stderrWriter();
        switch (err) {
            error.SyntaxError, error.UnexpectedToken, error.UnexpectedEndOfInput => try stderr.print(
                "error: session import: {s} is not valid JSON.\n  - Check the file was produced by `zcode session export`.\n",
                .{bundle_ref},
            ),
            error.InvalidBundle => try stderr.print(
                "error: session import: {s} is valid JSON but not a zcode session bundle.\n  - Expected top-level object with `history` array + `snapshot` object.\n  - Check the file was produced by `zcode session export`.\n",
                .{bundle_ref},
            ),
            else => try stderr.print(
                "error: session import: failed to import {s} ({s}).\n",
                .{ bundle_ref, @errorName(err) },
            ),
        }
        return error.BundleReadFailed;
    };
    defer allocator.free(session_id);
    try writer.print("imported session bundle into session {s}\n", .{session_id});
}

pub fn cmdSessionUndo(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    store: *session_store.Store,
    subject: ?[]const u8,
    checkpoint_id: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session undo");
    allocator.free(vpath);
    var restored = session_bundles.undoToCheckpoint(allocator, store, cwd, session_id, checkpoint_id) catch |err| switch (err) {
        error.CheckpointNotFound => {
            const stderr = std_io.stderrWriter();
            if (checkpoint_id) |label| {
                try stderr.print(
                    "error: session undo: no checkpoint '{s}' on session '{s}'.\n  - Run `zcode session checkpoints {s}` to see available labels.\n",
                    .{ label, session_id, session_id },
                );
            } else {
                try stderr.print(
                    "error: session undo: session '{s}' has no checkpoints to undo to.\n  - Create one first with `zcode session checkpoint {s}`.\n",
                    .{ session_id, session_id },
                );
            }
            return error.CheckpointNotFound;
        },
        else => return err,
    };
    defer restored.deinit(allocator);
    if (restored.backup_checkpoint_id) |backup_id| {
        try writer.print(
            "restored checkpoint {s} into new session {s}\tbackup={s}\n",
            .{ restored.checkpoint_id, restored.session_id, backup_id },
        );
    } else {
        try writer.print("restored checkpoint {s} into new session {s}\n", .{ restored.checkpoint_id, restored.session_id });
    }
}

pub fn cmdSessionRestore(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    store: *session_store.Store,
    subject: ?[]const u8,
    checkpoint_id: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session restore");
    allocator.free(vpath);
    var restored = session_bundles.undoToCheckpoint(allocator, store, cwd, session_id, checkpoint_id) catch |err| switch (err) {
        error.CheckpointNotFound => {
            const stderr = std_io.stderrWriter();
            if (checkpoint_id) |label| {
                try stderr.print(
                    "error: session restore: no checkpoint '{s}' on session '{s}'.\n  - Run `zcode session checkpoints {s}` to see available labels.\n",
                    .{ label, session_id, session_id },
                );
            } else {
                try stderr.print(
                    "error: session restore: session '{s}' has no checkpoints.\n  - Run `zcode session checkpoint {s}` to create one, or `zcode session checkpoints {s}` to list.\n",
                    .{ session_id, session_id, session_id },
                );
            }
            return error.CheckpointNotFound;
        },
        else => return err,
    };
    defer restored.deinit(allocator);
    if (restored.backup_checkpoint_id) |backup_id| {
        try writer.print(
            "restored checkpoint {s} into new session {s}\tbackup={s}\n",
            .{ restored.checkpoint_id, restored.session_id, backup_id },
        );
    } else {
        try writer.print("restored checkpoint {s} into new session {s}\n", .{ restored.checkpoint_id, restored.session_id });
    }
}

pub fn cmdSessionFork(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    label: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "session fork");
    allocator.free(vpath);
    var forked = try session_bundles.forkSession(allocator, store, session_id, label);
    defer forked.deinit(allocator);
    try writer.print(
        "forked session {s} into new session {s}\tlabel={s}\n",
        .{ forked.source_session_id, forked.session_id, forked.label },
    );
}

// --- Review command ---

pub fn cmdReview(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    subject: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    const prompt = review_flow.buildPrompt(allocator, subject) catch |err| switch (err) {
        error.InvalidReviewTarget => {
            // Usage error goes to stderr so `zcode review > out.md`
            // doesn't dump the usage banner into the user's output
            // file, and we propagate UsageErrorReported so main.zig
            // exits 2 instead of the previous silent exit 0.
            try std_io.stderrWriter().print(
                "error: review: {s}\n",
                .{review_flow.usage},
            );
            return error.UsageErrorReported;
        },
        else => return err,
    };
    defer allocator.free(prompt);

    try session_mgmt.runPluginEvent(allocator, writer, .{
        .event = .review_start,
        .cwd = cwd,
    });

    const AgentRuntime = agent_runtime.AgentRuntime;
    var runtime = try AgentRuntime.init(allocator, cwd, cfg, policy, audit, store, mcp, browser, false, auto_approve_high, strict, yolo_mode);
    defer runtime.deinit();

    if (initial_agent) |agent_name| {
        const activation = try runtime.activateAgentByNameStrict(agent_name);
        defer allocator.free(activation);
    }

    var result = try runtime.handlePromptDetailedWithModeAndReporter(prompt, null, .review);
    defer result.deinit(allocator);

    try writer.writeAll(result.final_text);
    if (!std.mem.endsWith(u8, result.final_text, "\n")) try writer.writeByte('\n');
}

// --- Daemon commands ---

pub fn cmdDaemonStart(allocator: std.mem.Allocator, writer: anytype) !void {
    const rendered = try remote_daemon.start(allocator);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdDaemonStatus(allocator: std.mem.Allocator, writer: anytype) !void {
    const rendered = try remote_daemon.status(allocator);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') try writer.writeByte('\n');
}

pub fn cmdDaemonStop(allocator: std.mem.Allocator, writer: anytype) !void {
    const rendered = try remote_daemon.stop(allocator);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdDaemonHandoff(
    allocator: std.mem.Allocator,
    store: *session_store.Store,
    subject: ?[]const u8,
    label: ?[]const u8,
    writer: anytype,
) !void {
    const session_id = subject orelse return error.MissingSessionId;
    const vpath = try assertSessionExists(allocator, store, session_id, "daemon handoff");
    allocator.free(vpath);
    const rendered = try remote_daemon.handoff(allocator, store, session_id, label);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') try writer.writeByte('\n');
}

// --- Trust commands ---

pub fn cmdTrustStatus(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const target = subject orelse cwd;
    const rendered = try trust_mod.renderStatus(allocator, target);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    const security = try security_mod.renderStatusSummary(allocator, target);
    defer allocator.free(security);
    try writer.writeAll(security);
}

pub fn cmdTrustAllow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const rendered = try trust_mod.allow(allocator, cwd, subject);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustRevoke(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const rendered = trust_mod.revoke(allocator, cwd, subject) catch |err| switch (err) {
        error.TrustEntryNotFound => {
            const target = subject orelse cwd;
            try std_io.stderrWriter().print(
                "error: trust revoke: no durable trust grant for '{s}'.\n  - Run `zcode trust status` to see current grants.\n",
                .{target},
            );
            return error.TrustEntryNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustHooks(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try security_mod.renderHookTrust(allocator, cwd);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdTrustHookAllow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const path = subject orelse return error.MissingToolArg;
    const rendered = security_mod.allowHook(allocator, cwd, path) catch |err| switch (err) {
        error.FileNotFound => {
            try std_io.stderrWriter().print(
                "error: trust hook-allow: file not found: {s}\n  - Trust grants are keyed by content hash, so the hook script must exist on disk.\n",
                .{path},
            );
            return error.HookFileNotFound;
        },
        error.AccessDenied => {
            try std_io.stderrWriter().print(
                "error: trust hook-allow: permission denied reading {s}\n  - Check the file's mode and owner; zcode does not elevate.\n",
                .{path},
            );
            return error.AccessDenied;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustHookRevoke(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const path = subject orelse return error.MissingToolArg;
    const rendered = security_mod.revokeHook(allocator, cwd, path) catch |err| switch (err) {
        error.HookTrustEntryNotFound => {
            try std_io.stderrWriter().print(
                "error: trust hook-revoke: no hook trust entry for '{s}'.\n  - Run `zcode trust hooks` to see trusted hook fingerprints.\n",
                .{path},
            );
            return error.HookTrustEntryNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustMarketplace(allocator: std.mem.Allocator, writer: anytype) !void {
    const rendered = try security_mod.renderMarketplacePolicy(allocator);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdTrustMarketplaceAllow(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const prefix = subject orelse return error.MissingToolArg;
    const rendered = try security_mod.allowMarketplacePrefix(allocator, prefix);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustMarketplaceBlock(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const prefix = subject orelse return error.MissingToolArg;
    const rendered = try security_mod.blockMarketplacePrefix(allocator, prefix);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdTrustMarketplaceUnblock(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const prefix = subject orelse return error.MissingToolArg;
    const rendered = security_mod.unblockMarketplacePrefix(allocator, prefix) catch |err| switch (err) {
        error.MarketplacePrefixNotBlocked => {
            try std_io.stderrWriter().print(
                "error: trust marketplace-unblock: prefix '{s}' is not in the blocklist.\n  - Run `zcode trust marketplace` to see current policy.\n",
                .{prefix},
            );
            return error.MarketplacePrefixNotBlocked;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

// --- Agents / Hooks commands ---

pub fn cmdAgentsList(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try agents_mod.renderList(allocator, cwd, null);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdAgentsShow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = try agents_mod.renderDetail(allocator, cwd, name);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdHooksList(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try hooks_mod.renderList(allocator, cwd);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

// --- Helpers ---

fn isRemoteBundleRef(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
}

const testing = std.testing;

test "isRemoteBundleRef detects URLs" {
    try testing.expect(isRemoteBundleRef("http://example.com/bundle.json"));
    try testing.expect(isRemoteBundleRef("https://example.com/bundle.json"));
    try testing.expect(!isRemoteBundleRef("/local/path/bundle.json"));
    try testing.expect(!isRemoteBundleRef("relative/path"));
    try testing.expect(!isRemoteBundleRef(""));
}

test "formatDisplaySessionId escapes control chars and truncates" {
    const alloc = testing.allocator;

    // Plain id passes through unchanged.
    const ok = try formatDisplaySessionId(alloc, "abc-123-f00");
    defer alloc.free(ok);
    try testing.expectEqualStrings("abc-123-f00", ok);

    // Embedded newline gets escaped so it cannot rewrap the terminal
    // output across lines.
    const newl = try formatDisplaySessionId(alloc, "abc\ndef");
    defer alloc.free(newl);
    try testing.expectEqualStrings("abc\\x0adef", newl);

    // DEL (0x7f) also gets escaped.
    const del = try formatDisplaySessionId(alloc, "a\x7fb");
    defer alloc.free(del);
    try testing.expectEqualStrings("a\\x7fb", del);

    // Overly long ids are truncated with a byte-count tail.
    const long_id = "a" ** 300;
    const trunc = try formatDisplaySessionId(alloc, long_id);
    defer alloc.free(trunc);
    try testing.expect(std.mem.indexOf(u8, trunc, "...(300 chars total)") != null);
    try testing.expect(trunc.len < 120);
}

// --- Marketplace commands ---

pub fn cmdMarketplaceSources(allocator: std.mem.Allocator, writer: anytype) !void {
    const rendered = try marketplace_mod.renderSources(allocator);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdMarketplaceAdd(
    allocator: std.mem.Allocator,
    subject: ?[]const u8,
    prompt: ?[]const u8,
    writer: anytype,
) !void {
    const name = subject orelse return error.MissingToolArg;
    const rest = prompt orelse return error.MissingToolArg;
    const split_idx = std.mem.indexOfScalar(u8, rest, ' ') orelse {
        const rendered = try marketplace_mod.addSource(allocator, name, rest, null);
        defer allocator.free(rendered);
        try writer.print("{s}\n", .{rendered});
        return;
    };
    const url = std.mem.trim(u8, rest[0..split_idx], " \t");
    const sha = std.mem.trim(u8, rest[split_idx + 1 ..], " \t");
    const rendered = try marketplace_mod.addSource(allocator, name, url, if (sha.len > 0) sha else null);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdMarketplaceRemove(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = marketplace_mod.removeSource(allocator, name) catch |err| switch (err) {
        error.MarketplaceEntryNotFound => {
            try std_io.stderrWriter().print(
                "error: marketplace remove: no source registered under '{s}'.\n  - Run `zcode marketplace sources` to see registered sources.\n",
                .{name},
            );
            return error.MarketplaceEntryNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdMarketplaceRefresh(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const rendered = try marketplace_mod.refreshSources(allocator, subject);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

// --- Plugin commands ---

pub fn cmdPluginsList(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try plugins_mod.renderList(allocator, cwd);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdPluginsShow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = plugins_mod.renderDetail(allocator, cwd, name) catch |err| switch (err) {
        error.PluginNotFound => {
            try std_io.stderrWriter().print(
                "error: plugins show: plugin '{s}' is not installed.\n  - Run `zcode plugins list` to see installed plugins.\n",
                .{name},
            );
            return error.PluginNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdPluginsMarketplace(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const rendered = if (subject) |name|
        try marketplace_mod.renderDetail(allocator, cwd, .plugin, name)
    else
        try marketplace_mod.renderList(allocator, cwd, .plugin);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') try writer.writeByte('\n');
}

pub fn cmdPluginsInstall(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = try marketplace_mod.install(allocator, cwd, .plugin, name);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdPluginsUninstall(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = marketplace_mod.uninstall(allocator, .plugin, name) catch |err| switch (err) {
        error.EntryNotInstalled => {
            try std_io.stderrWriter().print(
                "error: plugins uninstall: plugin '{s}' is not installed.\n  - Run `zcode plugins list` to see installed plugins.\n",
                .{name},
            );
            return error.EntryNotInstalled;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdPluginsUpdate(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = marketplace_mod.update(allocator, cwd, .plugin, name) catch |err| switch (err) {
        error.EntryNotInstalled => {
            try std_io.stderrWriter().print(
                "error: plugins update: plugin '{s}' is not installed.\n  - Run `zcode plugins list` to see installed plugins.\n",
                .{name},
            );
            return error.EntryNotInstalled;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

/// Resolve a `--scope` flag value to a PluginScope, defaulting to the most
/// specific scope: workspace if a workspace `.zcode` dir exists, else user
/// (mirrors the reference "most specific scope" docstring).
fn resolvePluginScope(allocator: std.mem.Allocator, cwd: []const u8, scope_arg: ?[]const u8) !plugins_mod.PluginScope {
    if (scope_arg) |s| {
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "workspace")) return .workspace;
        try std_io.stderrWriter().print(
            "error: plugins: unknown scope '{s}'. Use --scope user|workspace.\n",
            .{s},
        );
        return error.InvalidScope;
    }
    const ws_dir = try paths_mod.workspacePathAlloc(allocator, cwd, "");
    defer allocator.free(ws_dir);
    std.Io.Dir.cwd().access(rt.io, ws_dir, .{}) catch return .user;
    return .workspace;
}

/// Resolve a user-supplied plugin reference (bare `name` or `name@marketplace`)
/// to a canonical plugin_id. A bare name matches the first installed plugin of
/// that name; if none is installed the `name@local` sentinel is synthesized so
/// the toggle still records an entry. Caller owns the returned slice.
fn resolvePluginId(allocator: std.mem.Allocator, cwd: []const u8, reference: []const u8) ![]u8 {
    // Already an explicit id.
    if (std.mem.indexOfScalar(u8, reference, '@') != null) {
        return allocator.dupe(u8, reference);
    }
    const list = try plugins_mod.list(allocator, cwd);
    defer plugins_mod.freeList(allocator, list);
    for (list) |plugin| {
        if (std.mem.eql(u8, plugin.name, reference)) {
            return allocator.dupe(u8, plugin.plugin_id);
        }
    }
    return plugin_settings_mod.pluginId(allocator, reference, null);
}

pub fn cmdPluginsEnable(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, scope_arg: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const scope = try resolvePluginScope(allocator, cwd, scope_arg);
    const id = try resolvePluginId(allocator, cwd, name);
    defer allocator.free(id);
    // Org policy (plugins-07) beats the user/workspace enabledPlugins map: a
    // force-disabled plugin cannot be enabled at any scope.
    if (plugin_policy_mod.isBlockedByPolicy(allocator, id) catch false) {
        try std_io.stderrWriter().print(
            "error: plugins enable: '{s}' is force-disabled by org policy and cannot be enabled.\n",
            .{id},
        );
        return error.PluginBlockedByPolicy;
    }
    try plugin_settings_mod.setEnabled(allocator, cwd, scope, id, true);
    try writer.print("plugins: enabled {s} ({s} scope)\n", .{ id, plugins_mod.scopeName(scope) });
}

pub fn cmdPluginsDisable(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, scope_arg: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const scope = try resolvePluginScope(allocator, cwd, scope_arg);
    const id = try resolvePluginId(allocator, cwd, name);
    defer allocator.free(id);
    // A policy-managed plugin (any boolean policySettings entry) cannot be
    // disabled by the user - the org controls its state. Key on the bare name
    // (managedPluginNames returns names, not ids).
    const bare_name = id[0..(std.mem.indexOfScalar(u8, id, '@') orelse id.len)];
    if (plugin_policy_mod.isNameManaged(allocator, bare_name) catch false) {
        try std_io.stderrWriter().print(
            "error: plugins disable: '{s}' is managed by org policy and cannot be disabled.\n",
            .{id},
        );
        return error.PluginManagedByPolicy;
    }
    try plugin_settings_mod.setEnabled(allocator, cwd, scope, id, false);
    try writer.print("plugins: disabled {s} ({s} scope)\n", .{ id, plugins_mod.scopeName(scope) });
}

pub fn cmdPluginsDisableAll(allocator: std.mem.Allocator, cwd: []const u8, scope_arg: ?[]const u8, writer: anytype) !void {
    const scope = try resolvePluginScope(allocator, cwd, scope_arg);
    const count = try plugin_settings_mod.disableAll(allocator, cwd, scope);
    try writer.print("plugins: disabled {d} plugin(s) ({s} scope)\n", .{ count, plugins_mod.scopeName(scope) });
}

// --- Commands commands ---

pub fn cmdCommandsList(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try commands_mod.renderList(allocator, cwd);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdCommandsShow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = commands_mod.renderDetail(allocator, cwd, name) catch |err| switch (err) {
        error.CommandNotFound => {
            try std_io.stderrWriter().print(
                "error: commands show: command '{s}' is not installed.\n  - Run `zcode commands list` to see available commands.\n",
                .{name},
            );
            return error.CommandNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
}

pub fn cmdCommandsMarketplace(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const rendered = if (subject) |name|
        try marketplace_mod.renderDetail(allocator, cwd, .command, name)
    else
        try marketplace_mod.renderList(allocator, cwd, .command);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (rendered.len > 0 and rendered[rendered.len - 1] != '\n') try writer.writeByte('\n');
}

pub fn cmdCommandsInstall(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = try marketplace_mod.install(allocator, cwd, .command, name);
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdCommandsUninstall(allocator: std.mem.Allocator, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = marketplace_mod.uninstall(allocator, .command, name) catch |err| switch (err) {
        error.EntryNotInstalled => {
            try std_io.stderrWriter().print(
                "error: commands uninstall: command '{s}' is not installed.\n  - Run `zcode commands list` to see installed commands.\n",
                .{name},
            );
            return error.EntryNotInstalled;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdCommandsUpdate(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = marketplace_mod.update(allocator, cwd, .command, name) catch |err| switch (err) {
        error.EntryNotInstalled => {
            try std_io.stderrWriter().print(
                "error: commands update: command '{s}' is not installed.\n  - Run `zcode commands list` to see installed commands.\n",
                .{name},
            );
            return error.EntryNotInstalled;
        },
        else => return err,
    };
    defer allocator.free(rendered);
    try writer.print("{s}\n", .{rendered});
}

pub fn cmdCommandsRun(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    subject: ?[]const u8,
    args: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = commands_mod.renderRun(allocator, cwd, name, args orelse "") catch |err| switch (err) {
        error.CommandNotFound => {
            try std_io.stderrWriter().print(
                "error: commands run: command '{s}' is not installed.\n  - Run `zcode commands list` to see available commands.\n",
                .{name},
            );
            return error.CommandNotFound;
        },
        else => return err,
    };
    defer allocator.free(rendered);

    const one_shot = try session_mgmt.runOneShot(allocator, cwd, cfg, policy, audit, store, mcp, browser, rendered, false, auto_approve_high, strict, yolo_mode, initial_agent);
    defer allocator.free(one_shot.body);
    try writer.writeAll(one_shot.body);
    if (!std.mem.endsWith(u8, one_shot.body, "\n")) try writer.writeByte('\n');
}

pub fn cmdSkillsList(allocator: std.mem.Allocator, cwd: []const u8, writer: anytype) !void {
    const rendered = try skills_mod.renderList(allocator, cwd);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (!std.mem.endsWith(u8, rendered, "\n")) try writer.writeByte('\n');
}

pub fn cmdSkillsShow(allocator: std.mem.Allocator, cwd: []const u8, subject: ?[]const u8, writer: anytype) !void {
    const name = subject orelse return error.MissingToolArg;
    const rendered = try skills_mod.renderDetail(allocator, cwd, name);
    defer allocator.free(rendered);
    try writer.writeAll(rendered);
    if (!std.mem.endsWith(u8, rendered, "\n")) try writer.writeByte('\n');
}

pub fn cmdSkillsRun(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    cfg: *const config_mod.Config,
    policy: *policy_mod.Policy,
    audit: *logger_mod.AuditLogger,
    store: *session_store.Store,
    mcp: *mcp_client.Client,
    browser: ?*browser_bridge_mod.BrowserBridge,
    subject: ?[]const u8,
    args: ?[]const u8,
    writer: anytype,
    auto_approve_high: bool,
    strict: bool,
    yolo_mode: bool,
    initial_agent: ?[]const u8,
) !void {
    const name = subject orelse return error.MissingToolArg;
    // One-shot CLI skill run: no live session id is available before runOneShot
    // creates its own, so ${CLAUDE_SESSION_ID} renders empty here (skills-03).
    const rendered = try skills_mod.renderRun(allocator, cwd, name, args orelse "", "");
    defer allocator.free(rendered);

    const one_shot = try session_mgmt.runOneShot(allocator, cwd, cfg, policy, audit, store, mcp, browser, rendered, false, auto_approve_high, strict, yolo_mode, initial_agent);
    defer allocator.free(one_shot.body);
    try writer.writeAll(one_shot.body);
    if (!std.mem.endsWith(u8, one_shot.body, "\n")) try writer.writeByte('\n');
}

// --- Helpers ---

fn writeTempBundle(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    // Route through the central egress chokepoint before we touch
    // tmp dirs or curl. The previous policy was --proto =http,https
    // (allowing any plaintext HTTP host) with no SSRF guard, so a
    // user-supplied share URL like http://evil.example.com/bundle.json
    // (plaintext) or https://169.254.169.254/... (cloud metadata)
    // would be fetched directly via this code path.
    switch (egress.checkUrl(allocator, url, .{})) {
        .allow => {},
        .deny_scheme, .deny_ssrf, .deny_allowlist, .deny_denylist => return error.UrlPolicyDenied,
    }

    const tmp_root = @import("core/env.zig").getenv("TMPDIR") orelse "/tmp";

    // Symlink-attack hardening: the previous implementation built a
    // predictable file name like `zcode-share-<nanos>.json` directly in
    // $TMPDIR and passed it to `curl -o`. On a shared host, any other
    // local user could preplant a symlink at that path (the timestamp
    // is ~256 ns of entropy) and redirect curl's write to an arbitrary
    // file they chose. We now create a fresh per-download directory
    // with 64 bits of crypto entropy in its name, set its mode to
    // 0o700, and place the bundle file inside. mkdir() itself is
    // atomic and fails if the directory already exists, so an attacker
    // cannot race to create it first. The 0o700 mode means they
    // cannot plant a symlink inside it after creation either.
    const nonce = rng.int(u64);
    const dir_name = try std.fmt.allocPrint(allocator, "zcode-share-{x}", .{nonce});
    defer allocator.free(dir_name);
    const tmp_dir = try std.fs.path.join(allocator, &.{ tmp_root, dir_name });
    // `tmp_dir` is owned by this function for its entire lifetime. A
    // previous version freed it halfway through and left two errdefers
    // (free + deleteTree) referencing the now-dangling pointer, so any
    // later failure produced a use-after-free in deleteTree followed by
    // a double-free. Keep tmp_dir alive until function exit via defer.
    defer allocator.free(tmp_dir);

    try std.Io.Dir.cwd().createDir(rt.io, tmp_dir, .default_dir);
    // Gate the cleanup errdefer on a success flag so we only remove
    // the directory when the function is exiting via an error path.
    var keep_dir = false;
    errdefer if (!keep_dir) std.Io.Dir.cwd().deleteTree(rt.io, tmp_dir) catch {};
    // fchmodat by path instead of std.Io.Dir.chmod, which on Linux
    // panics in posix.fchmod (.BADF=>unreachable) when the dir is
    // opened in O_PATH mode.
    _ = std.c.chmod(@ptrCast(tmp_dir.ptr), 0o700);

    const path = try std.fs.path.join(allocator, &.{ tmp_dir, "bundle.json" });
    errdefer allocator.free(path);

    // egress.checkUrl above already validated the initial scheme +
    // SSRF policy. Pin redirect targets to https so a 3xx into
    // file:// / gopher:// / dict:// or a plaintext exfiltration
    // host is refused at the curl layer too. Cap at 16 MiB.
    // Bound the bundle fetch. 60s total + 10s connect-timeout is
    // plenty for the typical share-bundle JSON; without these flags
    // a hung share-server pinned the import flow forever (the user's
    // only recourse was Ctrl+C).
    const args = [_][]const u8{
        "curl",              "-fsSL",
        "--proto-redir",     "=https",
        "--connect-timeout", "10",
        "--max-time",        "60",
        "--max-filesize",    "16777216",
        "-o",                path,
        url,
    };
    const result = try std.process.run(allocator, rt.io, .{
        .argv = &args,
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.SessionBundleFetchFailed,
        else => return error.SessionBundleFetchFailed,
    }

    const file = try std.Io.Dir.cwd().openFile(rt.io, path, .{ .mode = .read_write });
    defer file.close(rt.io);
    file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};

    // Success: hand off ownership of `path` to the caller. The temp
    // directory must remain on disk because the caller still owns the
    // bundle inside it. Flip the cleanup flag so the errdefer above
    // doesn't remove it on normal return.
    keep_dir = true;
    return path;
}
