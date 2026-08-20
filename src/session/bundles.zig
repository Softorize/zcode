const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const paths = @import("../core/paths.zig");
const types = @import("../core/types.zig");
const store_mod = @import("store.zig");

const checkpoint_workspace_size_cap = 64 * 1024 * 1024;

pub const BundleKind = enum {
    checkpoint,
    share,
};

pub const SavedBundle = struct {
    id: []u8,
    path: []u8,
    label: []u8,

    pub fn deinit(self: *SavedBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.label);
    }
};

pub const CheckpointEntry = struct {
    id: []u8,
    label: []u8,
    path: []u8,
    created_ts: i64,

    pub fn deinit(self: *CheckpointEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.path);
    }
};

pub const UndoResult = struct {
    checkpoint_id: []u8,
    session_id: []u8,
    backup_checkpoint_id: ?[]u8 = null,

    pub fn deinit(self: *UndoResult, allocator: std.mem.Allocator) void {
        allocator.free(self.checkpoint_id);
        allocator.free(self.session_id);
        if (self.backup_checkpoint_id) |value| allocator.free(value);
    }
};

pub const ForkResult = struct {
    source_session_id: []u8,
    session_id: []u8,
    label: []u8,

    pub fn deinit(self: *ForkResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source_session_id);
        allocator.free(self.session_id);
        allocator.free(self.label);
    }
};

const WorkspaceMode = enum {
    none,
    git,
    files,
};

const WorkspaceEntryKind = enum {
    file,
    symlink,
};

const WorkspaceFileEntry = struct {
    relative_path: []u8,
    kind: WorkspaceEntryKind,
    executable: bool = false,
    symlink_target: ?[]u8 = null,

    fn deinit(self: *WorkspaceFileEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.relative_path);
        if (self.symlink_target) |value| allocator.free(value);
    }
};

const WorkspaceState = struct {
    mode: WorkspaceMode,
    workspace_root: ?[]u8 = null,
    repo_root: ?[]u8 = null,
    git_head: ?[]u8 = null,
    untracked_files: []WorkspaceFileEntry,
    files: []WorkspaceFileEntry,

    fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        if (self.workspace_root) |value| allocator.free(value);
        if (self.repo_root) |value| allocator.free(value);
        if (self.git_head) |value| allocator.free(value);
        freeWorkspaceEntries(allocator, self.untracked_files);
        freeWorkspaceEntries(allocator, self.files);
    }
};

const ParsedBundle = struct {
    conversation_summary: []u8,
    history: []types.HistoryTurn,
    snapshot: types.SessionSnapshot,

    fn deinit(self: *ParsedBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.conversation_summary);
        for (self.history) |turn| allocator.free(turn.content);
        allocator.free(self.history);
        freeStringList(allocator, self.snapshot.facts);
        freeStringList(allocator, self.snapshot.decisions);
        freeStringList(allocator, self.snapshot.open_tasks);
        freeStringList(allocator, self.snapshot.file_focus);
        freeStringList(allocator, self.snapshot.recent_tool_outcomes);
        allocator.free(self.snapshot.handoff_summary);
    }
};

const BundleMetadata = struct {
    id: []u8,
    label: []u8,
    created_ts: i64,
};

pub fn saveCheckpoint(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cwd: []const u8,
    session_id: []const u8,
    label: ?[]const u8,
) !SavedBundle {
    return writeBundle(allocator, store, session_id, label, .checkpoint, cwd);
}

pub fn shareSession(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    session_id: []const u8,
    label: ?[]const u8,
) !SavedBundle {
    return writeBundle(allocator, store, session_id, label, .share, null);
}

pub fn listCheckpointsForStore(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    session_id: []const u8,
) ![]CheckpointEntry {
    return listCheckpointsWithStoreRoot(allocator, store, session_id);
}

pub fn importBundleFile(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    bundle_path: []const u8,
) ![]u8 {
    var bundle = try parseBundleFile(allocator, bundle_path);
    defer bundle.deinit(allocator);

    const new_session_id = try store.createSessionId();
    errdefer allocator.free(new_session_id);

    for (bundle.history) |turn| {
        // Preserve the turn's uuid where present; appendTurn mints a fresh
        // one for legacy turns whose uuid is "".
        try store.appendTurn(new_session_id, turn.role, turn.content, turn.uuid);
    }
    try store.appendSnapshot(new_session_id, &bundle.snapshot, bundle.conversation_summary, "");
    return new_session_id;
}

pub fn undoToCheckpoint(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    cwd: []const u8,
    session_id: []const u8,
    checkpoint_id: ?[]const u8,
) !UndoResult {
    const checkpoints = try listCheckpointsForStore(allocator, store, session_id);
    defer freeCheckpointEntries(allocator, checkpoints);
    if (checkpoints.len == 0) return error.CheckpointNotFound;

    const chosen = if (checkpoint_id) |requested|
        findCheckpoint(checkpoints, requested) orelse return error.CheckpointNotFound
    else
        checkpoints[0];

    var backup = try saveCheckpoint(allocator, store, cwd, session_id, "pre-restore");
    defer backup.deinit(allocator);

    try restoreCheckpointWorkspace(allocator, cwd, chosen.path);

    const restored_session = try importBundleFile(allocator, store, chosen.path);
    errdefer allocator.free(restored_session);
    const checkpoint_id_copy = try allocator.dupe(u8, chosen.id);
    errdefer allocator.free(checkpoint_id_copy);
    const backup_id_copy = try allocator.dupe(u8, backup.id);
    return .{
        .checkpoint_id = checkpoint_id_copy,
        .session_id = restored_session,
        .backup_checkpoint_id = backup_id_copy,
    };
}

pub fn forkSession(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    session_id: []const u8,
    label: ?[]const u8,
) !ForkResult {
    var loaded = try store.load(session_id);
    defer loaded.deinit(allocator);

    return forkSessionFromState(
        allocator,
        store,
        session_id,
        loaded.history,
        &loaded.snapshot,
        loaded.conversation_summary,
        label,
    );
}

pub fn forkSessionFromState(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    source_session_id: []const u8,
    history: []const types.HistoryTurn,
    snapshot: *const types.SessionSnapshot,
    conversation_summary: []const u8,
    label: ?[]const u8,
) !ForkResult {
    const new_session_id = try store.createSessionId();
    errdefer allocator.free(new_session_id);

    for (history) |turn| {
        try store.appendTurn(new_session_id, turn.role, turn.content, turn.uuid);
    }
    try store.appendSnapshot(new_session_id, snapshot, conversation_summary, "");

    const trimmed = std.mem.trim(u8, label orelse "", " \t\r\n");
    const final_label = if (trimmed.len > 0) trimmed else "fork";

    const source_copy = try allocator.dupe(u8, source_session_id);
    errdefer allocator.free(source_copy);
    const label_copy = try allocator.dupe(u8, final_label);
    return .{
        .source_session_id = source_copy,
        .session_id = new_session_id,
        .label = label_copy,
    };
}

pub fn freeCheckpointEntries(allocator: std.mem.Allocator, entries: []CheckpointEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn listCheckpointsWithStoreRoot(
    allocator: std.mem.Allocator,
    store: ?*store_mod.Store,
    session_id: []const u8,
) ![]CheckpointEntry {
    const dir_path = try checkpointDirForSession(allocator, store, session_id);
    defer allocator.free(dir_path);

    var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(CheckpointEntry, 0),
        else => return err,
    };
    defer dir.close(rt.io);

    var out = std.array_list.Managed(CheckpointEntry).init(allocator);
    errdefer freeCheckpointEntries(allocator, out.items);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(path);
        const meta = try readBundleMetadata(allocator, path);
        errdefer {
            allocator.free(meta.id);
            allocator.free(meta.label);
        }
        try out.append(.{
            .id = meta.id,
            .label = meta.label,
            .path = path,
            .created_ts = meta.created_ts,
        });
    }

    std.mem.sort(CheckpointEntry, out.items, {}, lessRecentFirst);
    return out.toOwnedSlice();
}

fn writeBundle(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    session_id: []const u8,
    label: ?[]const u8,
    kind: BundleKind,
    cwd: ?[]const u8,
) !SavedBundle {
    var loaded = try store.load(session_id);
    defer loaded.deinit(allocator);

    const effective_label = std.mem.trim(u8, label orelse "", " \t\r\n");
    const final_label = if (effective_label.len > 0) effective_label else defaultLabel(kind);

    const dir_path = switch (kind) {
        .checkpoint => try checkpointDirForSession(allocator, store, session_id),
        .share => try sharesDir(allocator, store),
    };
    defer allocator.free(dir_path);
    try paths.ensureDir(dir_path);

    const bundle_id = try buildBundleId(allocator, final_label);
    errdefer allocator.free(bundle_id);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{bundle_id});
    defer allocator.free(file_name);
    const path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
    errdefer allocator.free(path);

    const bytes = try encodeBundle(allocator, session_id, final_label, kind, &loaded);
    defer allocator.free(bytes);

    // Atomic write: stage the bundle in a sibling .tmp file, fsync it,
    // then rename over the target. A crash mid-write previously left
    // the bundle half-written and shadowed any prior checkpoint with
    // the same id, so `undo` could permanently lose the user's work.
    try writeFileAtomic(allocator, path, bytes, 0o600);

    if (kind == .checkpoint and cwd != null) {
        try captureCheckpointWorkspace(allocator, cwd.?, path);
    }

    return .{
        .id = bundle_id,
        .path = path,
        .label = try allocator.dupe(u8, final_label),
    };
}

fn encodeBundle(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    label: []const u8,
    kind: BundleKind,
    loaded: *const store_mod.LoadedSession,
) ![]u8 {
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

    return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .bundle_type = "zcode-session-bundle",
        .bundle_version = 1,
        .bundle_kind = switch (kind) {
            .checkpoint => "checkpoint",
            .share => "share",
        },
        .created_ts = clock.nowSeconds(),
        .source_session_id = session_id,
        .label = label,
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

fn captureCheckpointWorkspace(allocator: std.mem.Allocator, cwd: []const u8, bundle_path: []const u8) !void {
    const workspace_dir = try checkpointWorkspaceDir(allocator, bundle_path);
    defer allocator.free(workspace_dir);
    if (fileExists(workspace_dir)) try std.Io.Dir.cwd().deleteTree(rt.io, workspace_dir);
    try paths.ensureDir(workspace_dir);

    if (try detectRepoRoot(allocator, cwd)) |repo_root| {
        defer allocator.free(repo_root);
        try captureGitWorkspace(allocator, cwd, repo_root, workspace_dir);
    } else {
        try captureFileWorkspace(allocator, cwd, workspace_dir);
    }
}

fn restoreCheckpointWorkspace(allocator: std.mem.Allocator, cwd: []const u8, bundle_path: []const u8) !void {
    const workspace_dir = try checkpointWorkspaceDir(allocator, bundle_path);
    defer allocator.free(workspace_dir);

    var state = loadWorkspaceState(allocator, workspace_dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer state.deinit(allocator);

    switch (state.mode) {
        .none => return,
        .git => try restoreGitWorkspace(allocator, cwd, workspace_dir, &state),
        .files => try restoreFileWorkspace(allocator, cwd, workspace_dir, &state),
    }
}

fn captureGitWorkspace(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    repo_root: []const u8,
    workspace_dir: []const u8,
) !void {
    _ = cwd;

    const git_head = try runCaptureTrimmed(allocator, &.{ "git", "-C", repo_root, "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    const staged_patch = try runCaptureAllowEmpty(allocator, &.{ "git", "-C", repo_root, "diff", "--cached", "--binary", "--no-color" }, 8 * 1024 * 1024);
    defer allocator.free(staged_patch);
    const unstaged_patch = try runCaptureAllowEmpty(allocator, &.{ "git", "-C", repo_root, "diff", "--binary", "--no-color" }, 8 * 1024 * 1024);
    defer allocator.free(unstaged_patch);

    if (staged_patch.len > 0) {
        const patch_path = try std.fs.path.join(allocator, &.{ workspace_dir, "staged.patch" });
        defer allocator.free(patch_path);
        // Atomic so an interrupt mid-write doesn't leave a half-
        // written patch that `git apply` would fail on during
        // restore. 0o600 because these bytes are the user's staged
        // diff - potentially sensitive.
        try writeFileAtomic(allocator, patch_path, staged_patch, 0o600);
    }

    if (unstaged_patch.len > 0) {
        const patch_path = try std.fs.path.join(allocator, &.{ workspace_dir, "unstaged.patch" });
        defer allocator.free(patch_path);
        try writeFileAtomic(allocator, patch_path, unstaged_patch, 0o600);
    }

    const untracked_root = try std.fs.path.join(allocator, &.{ workspace_dir, "untracked" });
    defer allocator.free(untracked_root);
    try paths.ensureDir(untracked_root);

    var untracked = std.array_list.Managed(WorkspaceFileEntry).init(allocator);
    defer {
        for (untracked.items) |*entry| entry.deinit(allocator);
        untracked.deinit();
    }

    const untracked_list = try runCaptureAllowEmpty(allocator, &.{ "git", "-C", repo_root, "ls-files", "--others", "--exclude-standard", "-z" }, 4 * 1024 * 1024);
    defer allocator.free(untracked_list);
    var it = std.mem.splitScalar(u8, untracked_list, 0);
    while (it.next()) |item| {
        const rel = std.mem.trim(u8, item, " \t\r\n");
        if (rel.len == 0) continue;
        try captureWorkspaceEntry(allocator, repo_root, untracked_root, rel, &untracked, null);
    }

    var state = WorkspaceState{
        .mode = .git,
        .workspace_root = null,
        .repo_root = try allocator.dupe(u8, repo_root),
        .git_head = try allocator.dupe(u8, git_head),
        .untracked_files = try untracked.toOwnedSlice(),
        .files = try allocator.alloc(WorkspaceFileEntry, 0),
    };
    defer state.deinit(allocator);
    try writeWorkspaceState(allocator, workspace_dir, &state);
}

fn captureFileWorkspace(allocator: std.mem.Allocator, cwd: []const u8, workspace_dir: []const u8) !void {
    const root_abs = try absolutePath(allocator, cwd);
    defer allocator.free(root_abs);

    const files_root = try std.fs.path.join(allocator, &.{ workspace_dir, "files" });
    defer allocator.free(files_root);
    try paths.ensureDir(files_root);

    var files = std.array_list.Managed(WorkspaceFileEntry).init(allocator);
    defer {
        for (files.items) |*entry| entry.deinit(allocator);
        files.deinit();
    }

    var total_bytes: usize = 0;
    try captureDirectoryEntries(allocator, root_abs, "", files_root, &files, &total_bytes);

    var state = WorkspaceState{
        .mode = .files,
        .workspace_root = try allocator.dupe(u8, root_abs),
        .repo_root = null,
        .git_head = null,
        .untracked_files = try allocator.alloc(WorkspaceFileEntry, 0),
        .files = try files.toOwnedSlice(),
    };
    defer state.deinit(allocator);
    try writeWorkspaceState(allocator, workspace_dir, &state);
}

fn restoreGitWorkspace(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    workspace_dir: []const u8,
    state: *const WorkspaceState,
) !void {
    const expected_root = state.repo_root orelse return error.InvalidBundle;
    const expected_head = state.git_head orelse return error.InvalidBundle;
    const current_root = (try detectRepoRoot(allocator, cwd)) orelse return error.CheckpointWorkspaceMismatch;
    defer allocator.free(current_root);

    if (!std.mem.eql(u8, current_root, expected_root)) return error.CheckpointWorkspaceMismatch;

    const current_head = try runCaptureTrimmed(allocator, &.{ "git", "-C", current_root, "rev-parse", "HEAD" });
    defer allocator.free(current_head);
    if (!std.mem.eql(u8, current_head, expected_head)) return error.CheckpointHeadMismatch;

    try runCommandChecked(allocator, &.{ "git", "-C", current_root, "reset", "--hard", "HEAD" }, 1024 * 1024);
    try runCommandChecked(allocator, &.{ "git", "-C", current_root, "clean", "-fd" }, 1024 * 1024);

    const staged_patch = try std.fs.path.join(allocator, &.{ workspace_dir, "staged.patch" });
    defer allocator.free(staged_patch);
    if (fileExists(staged_patch)) {
        try runCommandChecked(allocator, &.{ "git", "-C", current_root, "apply", "--binary", "--index", staged_patch }, 2 * 1024 * 1024);
    }

    const unstaged_patch = try std.fs.path.join(allocator, &.{ workspace_dir, "unstaged.patch" });
    defer allocator.free(unstaged_patch);
    if (fileExists(unstaged_patch)) {
        try runCommandChecked(allocator, &.{ "git", "-C", current_root, "apply", "--binary", unstaged_patch }, 2 * 1024 * 1024);
    }

    const untracked_root = try std.fs.path.join(allocator, &.{ workspace_dir, "untracked" });
    defer allocator.free(untracked_root);
    try restoreWorkspaceEntries(allocator, untracked_root, current_root, state.untracked_files);
}

fn restoreFileWorkspace(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    workspace_dir: []const u8,
    state: *const WorkspaceState,
) !void {
    const expected_root = state.workspace_root orelse return error.InvalidBundle;
    const current_root = try absolutePath(allocator, cwd);
    defer allocator.free(current_root);
    if (!std.mem.eql(u8, current_root, expected_root)) return error.CheckpointWorkspaceMismatch;

    try clearDirectoryContents(current_root);

    const files_root = try std.fs.path.join(allocator, &.{ workspace_dir, "files" });
    defer allocator.free(files_root);
    try restoreWorkspaceEntries(allocator, files_root, current_root, state.files);
}

fn captureDirectoryEntries(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    rel_dir: []const u8,
    snapshot_root: []const u8,
    out: *std.array_list.Managed(WorkspaceFileEntry),
    total_bytes: *usize,
) !void {
    const dir_path = if (rel_dir.len == 0)
        try allocator.dupe(u8, root_abs)
    else
        try std.fs.path.join(allocator, &.{ root_abs, rel_dir });
    defer allocator.free(dir_path);

    var dir = try std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true });
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const rel_path = if (rel_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ rel_dir, entry.name });
        defer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => try captureDirectoryEntries(allocator, root_abs, rel_path, snapshot_root, out, total_bytes),
            .file, .sym_link => try captureWorkspaceEntry(allocator, root_abs, snapshot_root, rel_path, out, total_bytes),
            else => {},
        }
    }
}

fn captureWorkspaceEntry(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    snapshot_root: []const u8,
    rel_path: []const u8,
    out: *std.array_list.Managed(WorkspaceFileEntry),
    total_bytes: ?*usize,
) !void {
    const source_path = try std.fs.path.join(allocator, &.{ root_abs, rel_path });
    defer allocator.free(source_path);

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(rt.io, source_path, &link_buf)) |link_n| {
        const target_slice = link_buf[0..link_n];
        try out.ensureUnusedCapacity(1);
        const target = try allocator.dupe(u8, target_slice);
        errdefer allocator.free(target);
        const rel_owned = try allocator.dupe(u8, rel_path);
        out.appendAssumeCapacity(.{
            .relative_path = rel_owned,
            .kind = .symlink,
            .executable = false,
            .symlink_target = target,
        });
        return;
    } else |_| {}

    const stat = try std.Io.Dir.cwd().statFile(rt.io, source_path, .{});
    if (stat.kind != .file) return;
    if (total_bytes) |value| {
        value.* += @intCast(stat.size);
        if (value.* > checkpoint_workspace_size_cap) return error.CheckpointWorkspaceTooLarge;
    }

    const destination = try std.fs.path.join(allocator, &.{ snapshot_root, rel_path });
    defer allocator.free(destination);
    try copyFileWithMode(source_path, destination);

    try out.ensureUnusedCapacity(1);
    const rel_owned = try allocator.dupe(u8, rel_path);
    out.appendAssumeCapacity(.{
        .relative_path = rel_owned,
        .kind = .file,
        .executable = (stat.permissions.toMode() & 0o111) != 0,
        .symlink_target = null,
    });
}

fn restoreWorkspaceEntries(
    allocator: std.mem.Allocator,
    snapshot_root: []const u8,
    destination_root: []const u8,
    entries: []const WorkspaceFileEntry,
) !void {
    for (entries) |entry| {
        // Reject path traversal and absolute paths in restored entries.
        if (std.fs.path.isAbsolute(entry.relative_path) or
            std.mem.indexOf(u8, entry.relative_path, "..") != null)
        {
            continue;
        }

        const destination = try std.fs.path.join(allocator, &.{ destination_root, entry.relative_path });
        defer allocator.free(destination);

        const parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
        try paths.ensureDir(parent);

        switch (entry.kind) {
            .file => {
                const source = try std.fs.path.join(allocator, &.{ snapshot_root, entry.relative_path });
                defer allocator.free(source);
                try copyFileWithMode(source, destination);
            },
            .symlink => {
                const target = entry.symlink_target orelse return error.InvalidBundle;
                if (std.fs.path.isAbsolute(target) or std.mem.indexOf(u8, target, "..") != null) {
                    continue;
                }
                std.Io.Dir.cwd().deleteFile(rt.io, destination) catch {};
                try std.Io.Dir.cwd().symLink(rt.io, target, destination, .{});
            },
        }
    }
}

fn clearDirectoryContents(root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(rt.io, root, .{ .iterate = true });
    defer dir.close(rt.io);

    var it = dir.iterate();
    while (try it.next(rt.io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        const child = try std.fs.path.join(std.heap.page_allocator, &.{ root, entry.name });
        defer std.heap.page_allocator.free(child);
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().deleteTree(rt.io, child),
            .file, .sym_link => try std.Io.Dir.cwd().deleteFile(rt.io, child),
            else => {},
        }
    }
}

fn checkpointWorkspaceDir(allocator: std.mem.Allocator, bundle_path: []const u8) ![]u8 {
    const stem = filenameStem(bundle_path);
    const dir = std.fs.path.dirname(bundle_path) orelse return error.InvalidPath;
    const name = try std.fmt.allocPrint(allocator, "{s}.workspace", .{stem});
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ dir, name });
}

fn readBundleMetadata(allocator: std.mem.Allocator, path: []const u8) !BundleMetadata {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(256 * 1024));
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBundle;
    const obj = parsed.value.object;

    const id_copy = try allocator.dupe(u8, filenameStem(path));
    errdefer allocator.free(id_copy);
    const label_copy = try allocator.dupe(u8, getString(obj, "label") orelse "");
    return .{
        .id = id_copy,
        .label = label_copy,
        .created_ts = getInteger(obj, "created_ts") orelse 0,
    };
}

fn parseBundleFile(allocator: std.mem.Allocator, path: []const u8) !ParsedBundle {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBundle;
    const obj = parsed.value.object;

    const history_value = obj.get("history") orelse return error.InvalidBundle;
    if (history_value != .array) return error.InvalidBundle;
    var history = std.array_list.Managed(types.HistoryTurn).init(allocator);
    errdefer {
        for (history.items) |turn| allocator.free(turn.content);
        history.deinit();
    }
    for (history_value.array.items) |item| {
        if (item != .object) continue;
        const role = getString(item.object, "role") orelse "user";
        const content = getString(item.object, "content") orelse "";
        const ts = getInteger(item.object, "timestamp") orelse clock.nowSeconds();
        try history.ensureUnusedCapacity(1);
        const owned_content = try allocator.dupe(u8, content);
        history.appendAssumeCapacity(.{
            .role = parseRole(role),
            .content = owned_content,
            .timestamp = ts,
        });
    }

    const snapshot_value = obj.get("snapshot") orelse return error.InvalidBundle;
    if (snapshot_value != .object) return error.InvalidBundle;
    const snapshot_obj = snapshot_value.object;

    const summary = try allocator.dupe(u8, getString(obj, "conversation_summary") orelse "");
    errdefer allocator.free(summary);
    const history_slice = try history.toOwnedSlice();
    errdefer {
        for (history_slice) |turn| allocator.free(turn.content);
        allocator.free(history_slice);
    }
    const facts = try copyJsonStringArray(allocator, snapshot_obj, "facts");
    errdefer freeStringList(allocator, facts);
    const decisions = try copyJsonStringArray(allocator, snapshot_obj, "decisions");
    errdefer freeStringList(allocator, decisions);
    const open_tasks = try copyJsonStringArray(allocator, snapshot_obj, "open_tasks");
    errdefer freeStringList(allocator, open_tasks);
    const file_focus = try copyJsonStringArray(allocator, snapshot_obj, "file_focus");
    errdefer freeStringList(allocator, file_focus);
    const recent_outcomes = try copyJsonStringArray(allocator, snapshot_obj, "recent_tool_outcomes");
    errdefer freeStringList(allocator, recent_outcomes);
    const handoff = try allocator.dupe(u8, getString(snapshot_obj, "handoff_summary") orelse "");
    return .{
        .conversation_summary = summary,
        .history = history_slice,
        .snapshot = .{
            .facts = facts,
            .decisions = decisions,
            .open_tasks = open_tasks,
            .file_focus = file_focus,
            .recent_tool_outcomes = recent_outcomes,
            .handoff_summary = handoff,
        },
    };
}

fn loadWorkspaceState(allocator: std.mem.Allocator, workspace_dir: []const u8) !WorkspaceState {
    const state_path = try std.fs.path.join(allocator, &.{ workspace_dir, "state.json" });
    defer allocator.free(state_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, state_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidBundle;
    const obj = parsed.value.object;

    return .{
        .mode = parseWorkspaceMode(getString(obj, "mode") orelse "none"),
        .workspace_root = if (getString(obj, "workspace_root")) |value| try allocator.dupe(u8, value) else null,
        .repo_root = if (getString(obj, "repo_root")) |value| try allocator.dupe(u8, value) else null,
        .git_head = if (getString(obj, "git_head")) |value| try allocator.dupe(u8, value) else null,
        .untracked_files = try copyWorkspaceEntries(allocator, obj.get("untracked_files")),
        .files = try copyWorkspaceEntries(allocator, obj.get("files")),
    };
}

fn writeWorkspaceState(allocator: std.mem.Allocator, workspace_dir: []const u8, state: *const WorkspaceState) !void {
    const state_path = try std.fs.path.join(allocator, &.{ workspace_dir, "state.json" });
    defer allocator.free(state_path);

    const JsonEntry = struct {
        path: []const u8,
        kind: []const u8,
        executable: bool,
        symlink_target: ?[]const u8,
    };

    const untracked = try allocator.alloc(JsonEntry, state.untracked_files.len);
    defer allocator.free(untracked);
    for (state.untracked_files, 0..) |entry, idx| {
        untracked[idx] = .{
            .path = entry.relative_path,
            .kind = workspaceEntryKindName(entry.kind),
            .executable = entry.executable,
            .symlink_target = entry.symlink_target,
        };
    }

    const files = try allocator.alloc(JsonEntry, state.files.len);
    defer allocator.free(files);
    for (state.files, 0..) |entry, idx| {
        files[idx] = .{
            .path = entry.relative_path,
            .kind = workspaceEntryKindName(entry.kind),
            .executable = entry.executable,
            .symlink_target = entry.symlink_target,
        };
    }

    const bytes = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(.{
        .mode = workspaceModeName(state.mode),
        .workspace_root = state.workspace_root,
        .repo_root = state.repo_root,
        .git_head = state.git_head,
        .untracked_files = untracked,
        .files = files,
    }, .{})});
    defer allocator.free(bytes);

    // Atomic: a SIGINT (or kill -9) mid-write used to leave a
    // partial state.json that any subsequent restore would reject.
    // writeFileAtomic writes a sibling .tmp and renames, so readers
    // only ever see either the old content or the complete new one.
    try writeFileAtomic(allocator, state_path, bytes, 0o600);
}

fn copyWorkspaceEntries(allocator: std.mem.Allocator, value: ?std.json.Value) ![]WorkspaceFileEntry {
    const arr = value orelse return allocator.alloc(WorkspaceFileEntry, 0);
    if (arr != .array) return allocator.alloc(WorkspaceFileEntry, 0);

    var out = std.array_list.Managed(WorkspaceFileEntry).init(allocator);
    // Free every already-appended entry's owned strings on error exit.
    // Previously `defer out.deinit()` only freed the backing storage,
    // leaking every appended relative_path + symlink_target dupe.
    errdefer {
        for (out.items) |entry| {
            allocator.free(entry.relative_path);
            if (entry.symlink_target) |t| allocator.free(t);
        }
        out.deinit();
    }
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const path = getString(item.object, "path") orelse continue;
        const kind = parseWorkspaceEntryKind(getString(item.object, "kind") orelse "file");

        // Reserve slot first so the final append is infallible; stage
        // both dupes with iteration-scoped errdefers. Previously a
        // failure in the symlink_target dupe leaked relative_path, and
        // a failing append leaked both.
        try out.ensureUnusedCapacity(1);
        const rel_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(rel_owned);
        const symlink_target: ?[]u8 = if (getString(item.object, "symlink_target")) |target|
            try allocator.dupe(u8, target)
        else
            null;
        out.appendAssumeCapacity(.{
            .relative_path = rel_owned,
            .kind = kind,
            .executable = getBool(item.object, "executable") orelse false,
            .symlink_target = symlink_target,
        });
    }
    return out.toOwnedSlice();
}

fn freeWorkspaceEntries(allocator: std.mem.Allocator, entries: []WorkspaceFileEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

fn checkpointDirForSession(allocator: std.mem.Allocator, store: ?*store_mod.Store, session_id: []const u8) ![]u8 {
    try store_mod.validateSessionId(session_id);
    const root = try checkpointsRoot(allocator, store);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, session_id });
}

fn checkpointsRoot(allocator: std.mem.Allocator, store: ?*store_mod.Store) ![]u8 {
    const base = try storeBaseDir(allocator, store);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "checkpoints" });
}

fn sharesDir(allocator: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    const base = try storeBaseDir(allocator, store);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "shares" });
}

fn storeBaseDir(allocator: std.mem.Allocator, store: ?*store_mod.Store) ![]u8 {
    const active_store = store orelse return error.MissingStore;
    const parent = std.fs.path.dirname(active_store.sessions_dir) orelse return error.InvalidPath;
    return allocator.dupe(u8, parent);
}

fn buildBundleId(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    const slug = try slugify(allocator, label);
    defer allocator.free(slug);
    return std.fmt.allocPrint(allocator, "{d}-{s}", .{ clock.nowSeconds(), slug });
}

fn slugify(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (label) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            try out.append(std.ascii.toLower(ch));
        } else if (ch == '-' or ch == '_' or ch == ' ' or ch == '.') {
            if (out.items().len == 0 or out.items()[out.items().len - 1] == '-') continue;
            try out.append('-');
        }
    }

    while (out.items().len > 0 and out.items()[out.items().len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items().len == 0) try out.appendSlice("bundle");
    return out.toOwnedSlice();
}

fn defaultLabel(kind: BundleKind) []const u8 {
    return switch (kind) {
        .checkpoint => "checkpoint",
        .share => "share",
    };
}

fn filenameStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (std.mem.endsWith(u8, base, ".json")) base[0 .. base.len - ".json".len] else base;
}

fn findCheckpoint(entries: []const CheckpointEntry, requested: []const u8) ?CheckpointEntry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, requested) or std.mem.eql(u8, entry.label, requested)) return entry;
    }
    return null;
}

fn detectRepoRoot(allocator: std.mem.Allocator, cwd: []const u8) !?[]u8 {
    const result = std.process.run(allocator, rt.io, .{
        .argv = &.{ "git", "-C", cwd, "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return null;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (!(result.term == .exited and result.term.exited == 0)) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return allocator.dupe(u8, path) catch {
        if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
        const current = try std.process.currentPathAlloc(rt.io, allocator);
        defer allocator.free(current);
        return std.fs.path.join(allocator, &.{ current, path });
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn copyJsonStringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const value = obj.get(key) orelse return allocator.alloc([]const u8, 0);
    if (value != .array) return allocator.alloc([]const u8, 0);

    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    for (value.array.items) |item| {
        if (item != .string) continue;
        const dup = try allocator.dupe(u8, item.string);
        out.append(dup) catch |err| {
            allocator.free(dup);
            return err;
        };
    }
    return out.toOwnedSlice();
}

const freeStringList = @import("../core/parse_helpers.zig").freeStringSlice;

fn parseRole(role: []const u8) types.HistoryRole {
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "system")) return .system;
    if (std.mem.eql(u8, role, "tool")) return .tool;
    return .user;
}

fn parseWorkspaceMode(value: []const u8) WorkspaceMode {
    if (std.mem.eql(u8, value, "git")) return .git;
    if (std.mem.eql(u8, value, "files")) return .files;
    return .none;
}

fn workspaceModeName(mode: WorkspaceMode) []const u8 {
    return switch (mode) {
        .none => "none",
        .git => "git",
        .files => "files",
    };
}

fn parseWorkspaceEntryKind(value: []const u8) WorkspaceEntryKind {
    if (std.mem.eql(u8, value, "symlink")) return .symlink;
    return .file;
}

fn workspaceEntryKindName(kind: WorkspaceEntryKind) []const u8 {
    return switch (kind) {
        .file => "file",
        .symlink => "symlink",
    };
}

fn runCaptureTrimmed(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    if (!(result.term == .exited and result.term.exited == 0)) return error.CommandFailed;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn runCaptureAllowEmpty(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) ![]u8 {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stderr);

    if (!(result.term == .exited and result.term.exited == 0)) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

fn runCommandChecked(allocator: std.mem.Allocator, argv: []const []const u8, max_output: usize) !void {
    const result = try std.process.run(allocator, rt.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!(result.term == .exited and result.term.exited == 0)) return error.CommandFailed;
}

fn copyFileWithMode(source: []const u8, destination: []const u8) !void {
    const src_file = try std.Io.Dir.cwd().openFile(rt.io, source, .{});
    defer src_file.close(rt.io);
    const src_stat = try src_file.stat(rt.io);

    const parent = std.fs.path.dirname(destination) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    // Atomic write: this is called during `session restore` to
    // overwrite files in the user's live workspace. A SIGINT in the
    // middle of the read/write loop on a multi-MB file would leave
    // the destination at whatever bytes had been flushed so far --
    // i.e., the user's tracked workspace file is now truncated /
    // half-written. Stage into a sibling .tmp.<nonce>, fsync, then
    // rename so a crash mid-restore can never expose a torn file.
    var nonce: [8]u8 = undefined;
    rng.secureBytes(&nonce);
    var name_buf: [40]u8 = undefined;
    const tmp_suffix = std.fmt.bufPrint(&name_buf, ".tmp.{x}{x}{x}{x}{x}{x}{x}{x}", .{
        nonce[0], nonce[1], nonce[2], nonce[3], nonce[4], nonce[5], nonce[6], nonce[7],
    }) catch unreachable;
    var tmp_path_buf = std_io.StringBuilder.init(std.heap.page_allocator);
    defer tmp_path_buf.deinit();
    try tmp_path_buf.appendSlice(destination);
    try tmp_path_buf.appendSlice(tmp_suffix);
    const tmp_path = tmp_path_buf.items();
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};

    {
        const dst_file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true });
        defer dst_file.close(rt.io);

        var buf: [8192]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try src_file.readPositionalAll(rt.io, &buf, offset);
            if (n == 0) break;
            try dst_file.writeStreamingAll(rt.io, buf[0..n]);
            offset += n;
            if (n < buf.len) break;
        }
        dst_file.sync(rt.io) catch {};
        dst_file.setPermissions(rt.io, src_stat.permissions) catch {};
    }
    try std.Io.Dir.renameAbsolute(tmp_path, destination, rt.io);
}

fn writeFile(path_path: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(path_path) orelse return error.InvalidPath;
    try paths.ensureDir(parent);
    const file = try std.Io.Dir.cwd().createFile(rt.io, path_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, bytes);
    file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
}

/// Write `bytes` to `target` atomically by staging in a sibling `.tmp`,
/// fsyncing, then renaming over the final path. This guarantees a crash
/// during the write cannot leave the target half-written or truncated.
fn writeFileAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8, mode: u16) !void {
    const parent = std.fs.path.dirname(target) orelse return error.InvalidPath;
    try paths.ensureDir(parent);

    // Use a nanosecond suffix so two concurrent writers do not collide on
    // the same tmp path.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ target, clock.nowNanos() });
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

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return false;
    return true;
}

fn lessRecentFirst(_: void, a: CheckpointEntry, b: CheckpointEntry) bool {
    return a.created_ts > b.created_ts;
}

const testing = std.testing;

fn initGitRepo(cwd: []const u8) !void {
    try runCommandChecked(testing.allocator, &.{ "git", "-C", cwd, "init" }, 256 * 1024);
    try runCommandChecked(testing.allocator, &.{ "git", "-C", cwd, "config", "user.email", "test@example.com" }, 64 * 1024);
    try runCommandChecked(testing.allocator, &.{ "git", "-C", cwd, "config", "user.name", "zcode test" }, 64 * 1024);
}

test "checkpoint bundle roundtrip" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer allocator.free(sessions_dir);

    var store = try store_mod.Store.init(allocator, sessions_dir, false);
    defer store.deinit();

    const session_id = try store.createSessionId();
    defer allocator.free(session_id);

    try store.appendTurn(session_id, .user, "hello", "");
    try store.appendTurn(session_id, .assistant, "world", "");

    var snapshot = store_mod.emptySnapshot();
    snapshot.handoff_summary = "handoff";
    try store.appendSnapshot(session_id, &snapshot, "summary", "");

    var bundle = try shareSession(allocator, &store, session_id, "smoke");
    defer bundle.deinit(allocator);

    const imported = try importBundleFile(allocator, &store, bundle.path);
    defer allocator.free(imported);

    var loaded = try store.load(imported);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), loaded.history.len);
    try testing.expectEqualStrings("summary", loaded.conversation_summary);
}

test "checkpoint restore resets git workspace and imports new session" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io, "repo");
    try tmp.dir.createDirPath(rt.io, "state/sessions");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "repo/tracked.txt", .data = "base\n" });

    const repo_cwd = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo");
    defer allocator.free(repo_cwd);
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "state/sessions");
    defer allocator.free(sessions_dir);

    try initGitRepo(repo_cwd);
    try runCommandChecked(allocator, &.{ "git", "-C", repo_cwd, "add", "tracked.txt" }, 128 * 1024);
    try runCommandChecked(allocator, &.{ "git", "-C", repo_cwd, "commit", "-m", "init" }, 256 * 1024);

    var store = try store_mod.Store.init(allocator, sessions_dir, false);
    defer store.deinit();

    const session_id = try store.createSessionId();
    defer allocator.free(session_id);
    try store.appendTurn(session_id, .user, "checkpoint me", "");
    var snapshot = store_mod.emptySnapshot();
    try store.appendSnapshot(session_id, &snapshot, "summary", "");

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "repo/tracked.txt", .data = "staged\n" });
    try runCommandChecked(allocator, &.{ "git", "-C", repo_cwd, "add", "tracked.txt" }, 128 * 1024);

    const tracked_abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo/tracked.txt");
    defer allocator.free(tracked_abs);
    try writeFile(tracked_abs, "staged\nunstaged\n");
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "repo/new.txt", .data = "hello\n" });

    var checkpoint = try saveCheckpoint(allocator, &store, repo_cwd, session_id, "git-restore");
    defer checkpoint.deinit(allocator);

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "repo/tracked.txt", .data = "different\n" });
    try runCommandChecked(allocator, &.{ "git", "-C", repo_cwd, "add", "-A" }, 128 * 1024);
    const delete_new_abs = try std.fs.path.join(allocator, &.{ repo_cwd, "new.txt" });
    defer allocator.free(delete_new_abs);
    std.Io.Dir.cwd().deleteFile(rt.io, delete_new_abs) catch {};

    var restored = try undoToCheckpoint(allocator, &store, repo_cwd, session_id, checkpoint.id);
    defer restored.deinit(allocator);
    try testing.expect(restored.backup_checkpoint_id != null);

    const final_tracked = try std.Io.Dir.cwd().readFileAlloc(rt.io, tracked_abs, allocator, .limited(1024));
    defer allocator.free(final_tracked);
    try testing.expectEqualStrings("staged\nunstaged\n", final_tracked);

    const new_abs = try @import("../core/test_helpers.zig").tmpDirPath(testing.allocator, &tmp, "repo/new.txt");
    defer allocator.free(new_abs);
    const final_new = try std.Io.Dir.cwd().readFileAlloc(rt.io, new_abs, allocator, .limited(1024));
    defer allocator.free(final_new);
    try testing.expectEqualStrings("hello\n", final_new);

    const staged = try runCaptureAllowEmpty(allocator, &.{ "git", "-C", repo_cwd, "diff", "--cached", "--name-only" }, 64 * 1024);
    defer allocator.free(staged);
    try testing.expect(std.mem.indexOf(u8, staged, "tracked.txt") != null);

    const unstaged = try runCaptureAllowEmpty(allocator, &.{ "git", "-C", repo_cwd, "diff", "--name-only" }, 64 * 1024);
    defer allocator.free(unstaged);
    try testing.expect(std.mem.indexOf(u8, unstaged, "tracked.txt") != null);

    var loaded = try store.load(restored.session_id);
    defer loaded.deinit(allocator);
    try testing.expectEqualStrings("summary", loaded.conversation_summary);
}

test "checkpoint restore works for non-git workspace" {
    const allocator = testing.allocator;
    const tmp_root = @import("../core/env.zig").getOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_root);
    const unique = try std.fmt.allocPrint(allocator, "zcode-non-git-{d}", .{clock.nowNanos()});
    defer allocator.free(unique);
    const external_root = try std.fs.path.join(allocator, &.{ tmp_root, unique });
    defer allocator.free(external_root);
    defer std.Io.Dir.cwd().deleteTree(rt.io, external_root) catch {};

    try std.Io.Dir.cwd().createDirPath(rt.io, external_root);
    const workspace_cwd = try std.fs.path.join(allocator, &.{ external_root, "workspace" });
    defer allocator.free(workspace_cwd);
    const sessions_dir = try std.fs.path.join(allocator, &.{ external_root, "state", "sessions" });
    defer allocator.free(sessions_dir);

    try std.Io.Dir.cwd().createDirPath(rt.io, workspace_cwd);
    try std.Io.Dir.cwd().createDirPath(rt.io, sessions_dir);

    const demo_abs = try std.fs.path.join(allocator, &.{ workspace_cwd, "demo.txt" });
    defer allocator.free(demo_abs);
    try writeFile(demo_abs, "before\n");

    var store = try store_mod.Store.init(allocator, sessions_dir, false);
    defer store.deinit();

    const session_id = try store.createSessionId();
    defer allocator.free(session_id);
    try store.appendTurn(session_id, .user, "save files", "");
    var snapshot = store_mod.emptySnapshot();
    try store.appendSnapshot(session_id, &snapshot, "summary", "");

    var checkpoint = try saveCheckpoint(allocator, &store, workspace_cwd, session_id, "files");
    defer checkpoint.deinit(allocator);

    const checkpoint_workspace = try checkpointWorkspaceDir(allocator, checkpoint.path);
    defer allocator.free(checkpoint_workspace);
    const checkpoint_demo = try std.fs.path.join(allocator, &.{ checkpoint_workspace, "files", "demo.txt" });
    defer allocator.free(checkpoint_demo);
    const checkpoint_demo_bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, checkpoint_demo, allocator, .limited(1024));
    defer allocator.free(checkpoint_demo_bytes);
    try testing.expectEqualStrings("before\n", checkpoint_demo_bytes);

    try writeFile(demo_abs, "after\n");
    const extra_abs = try std.fs.path.join(allocator, &.{ workspace_cwd, "extra.txt" });
    defer allocator.free(extra_abs);
    try writeFile(extra_abs, "temp\n");

    var restored = try undoToCheckpoint(allocator, &store, workspace_cwd, session_id, checkpoint.id);
    defer restored.deinit(allocator);

    const demo_bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, demo_abs, allocator, .limited(1024));
    defer allocator.free(demo_bytes);
    try testing.expectEqualStrings("before\n", demo_bytes);

    try testing.expect(!fileExists(extra_abs));
}
