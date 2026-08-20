const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const uuid = @import("../core/uuid.zig");
const clock = @import("../core/clock.zig");
const types = @import("../core/types.zig");
const paths = @import("../core/paths.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const keychain = @import("../core/keychain.zig");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const session_key_env = "ZCODE_SESSION_KEY";
const session_keychain_account = "__session_key__";
const encrypted_record_type = "encrypted_v1";

pub const SessionEntry = struct {
    id: []u8,
    updated_ts: i64,
    /// Optional human-readable label set via /rename. Stored as a
    /// sidecar file `<id>.label` next to `<id>.jsonl`. null when the
    /// session has no label (which is every session until the user
    /// renames it). Owned by the entry; freed via freeSessionEntries.
    label: ?[]u8 = null,
    /// Optional list of tags set via `/tag add`. Stored as a sidecar
    /// file `<id>.tags` with one newline-delimited tag per line.
    /// Empty slice when the session has no tags yet. Owned by the
    /// entry; freed via freeSessionEntries.
    tags: [][]u8 = &.{},
};

pub const LoadedSession = struct {
    id: []u8,
    history: []types.HistoryTurn,
    snapshot: types.SessionSnapshot,
    conversation_summary: []u8,
    /// Optional breadcrumb recording the working directory the session
    /// was last active in (sessions-04). Persisted on the snapshot
    /// record so a picker can display "(from <dir>)" without any
    /// cross-project resume machinery. Empty string when no snapshot
    /// carried an origin (legacy sessions, or replay-created sessions
    /// that pass "" through appendSnapshot). Always owned/duped so the
    /// matching free is unconditional.
    origin_cwd: []u8,

    pub fn deinit(self: *LoadedSession, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        for (self.history) |turn| {
            allocator.free(turn.content);
            allocator.free(@constCast(turn.uuid));
        }
        allocator.free(self.history);

        freeStringList(allocator, self.snapshot.facts);
        freeStringList(allocator, self.snapshot.decisions);
        freeStringList(allocator, self.snapshot.open_tasks);
        freeStringList(allocator, self.snapshot.file_focus);
        freeStringList(allocator, self.snapshot.recent_tool_outcomes);
        allocator.free(self.snapshot.handoff_summary);
        freeStringList(allocator, self.snapshot.pinned_facts);
        freeStringList(allocator, self.snapshot.completed_tasks);
        freeStringList(allocator, self.snapshot.activated_conditional_skills);

        allocator.free(self.conversation_summary);
        allocator.free(self.origin_cwd);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    sessions_dir: []u8,
    encryption_enabled: bool,
    encryption_key: ?[Aes256Gcm.key_length]u8,

    pub fn init(allocator: std.mem.Allocator, sessions_dir: []const u8, encryption_enabled: bool) !Store {
        try paths.ensureDir(sessions_dir);
        const key = try loadSessionKey(allocator, encryption_enabled);
        return .{
            .allocator = allocator,
            .sessions_dir = try allocator.dupe(u8, sessions_dir),
            .encryption_enabled = encryption_enabled,
            .encryption_key = key,
        };
    }

    /// Generate a fresh random 256-bit session key, store it in the OS
    /// keychain (overwriting any prior key), and return the new key.
    /// Existing encrypted sessions written under the old key become
    /// unreadable after rotation - callers that need graceful rotation
    /// should export or decrypt first.
    pub fn rotateSessionKey(allocator: std.mem.Allocator) ![Aes256Gcm.key_length]u8 {
        var new_key: [Aes256Gcm.key_length]u8 = undefined;
        rng.secureBytes(&new_key);
        try storeKeyInKeychain(allocator, new_key);
        return new_key;
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.sessions_dir);
    }

    pub fn createSessionId(self: *Store) ![]u8 {
        // 128-bit nonce from the crypto RNG. The previous 32-bit nonce
        // had a birthday-collision expectation around ~65K sessions
        // started in the same second; under concurrent REPL usage or
        // bulk automation that risked session-file clobber (session IDs
        // are used as filenames). 128 bits is collision-free at every
        // realistic scale.
        var nonce_hex: [32]u8 = undefined;
        uuid.rawHex32(&nonce_hex);
        return std.fmt.allocPrint(self.allocator, "{d}-{s}", .{ clock.nowSeconds(), nonce_hex });
    }

    /// Append a turn record to the session JSONL. `turn_uuid` is the
    /// stable per-turn id; pass "" to have the store mint a fresh
    /// canonical UUID-v4 (the common replay path -- e.g. resuming a
    /// bundle). When the in-memory `History` already minted a uuid for
    /// the live turn it passes that same id so the on-disk record and the
    /// in-memory turn share it.
    pub fn appendTurn(self: *Store, session_id: []const u8, role: types.HistoryRole, content: []const u8, turn_uuid: []const u8) !void {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        const file = try openAppendFile(path);
        defer file.close(rt.io);
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("session: failed to chmod {s}: {s}", .{ path, @errorName(err) });
        };

        var minted: [36]u8 = undefined;
        const effective_uuid: []const u8 = if (turn_uuid.len > 0) turn_uuid else blk: {
            uuid.v4Hex(&minted);
            break :blk &minted;
        };

        var record_buf = std_io.StringBuilder.init(self.allocator);
        defer record_buf.deinit();

        try record_buf.writer().print("{f}", .{std.json.fmt(.{
            .type = "turn",
            .role = types.roleToString(role),
            .content = content,
            .timestamp = clock.nowSeconds(),
            .uuid = effective_uuid,
        }, .{})});

        try self.appendRecordLine(file, record_buf.items());
    }

    /// Append a snapshot record. `origin_cwd` is an optional breadcrumb
    /// (sessions-04) recording the working directory the session was
    /// active in; pass "" for replay-created sessions where origin has
    /// no meaning (bundle restore, CLI re-snapshot). The live REPL path
    /// passes the runtime's cwd so a picker can later display origin.
    pub fn appendSnapshot(self: *Store, session_id: []const u8, snapshot: *const types.SessionSnapshot, conversation_summary: []const u8, origin_cwd: []const u8) !void {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        const file = try openAppendFile(path);
        defer file.close(rt.io);
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("session: failed to chmod {s}: {s}", .{ path, @errorName(err) });
        };

        var record_buf = std_io.StringBuilder.init(self.allocator);
        defer record_buf.deinit();

        try record_buf.writer().print("{f}", .{std.json.fmt(.{
            .type = "snapshot",
            .conversation_summary = conversation_summary,
            .facts = snapshot.facts,
            .decisions = snapshot.decisions,
            .open_tasks = snapshot.open_tasks,
            .file_focus = snapshot.file_focus,
            .recent_tool_outcomes = snapshot.recent_tool_outcomes,
            .handoff_summary = snapshot.handoff_summary,
            .pinned_facts = snapshot.pinned_facts,
            .completed_tasks = snapshot.completed_tasks,
            .activated_conditional_skills = snapshot.activated_conditional_skills,
            .origin_cwd = origin_cwd,
            .message_count_at_snapshot = snapshot.message_count_at_snapshot,
            .timestamp = clock.nowSeconds(),
        }, .{})});

        try self.appendRecordLine(file, record_buf.items());
    }

    pub fn load(self: *Store, session_id: []const u8) !LoadedSession {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        // Session JSONL files grow with history. 8 MiB was too small for real
        // coding sessions and caused silent data-loss when the next load returned
        // FileTooBig. 256 MiB gives us multi-day sessions before needing compaction.
        const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(256 * 1024 * 1024));
        defer self.allocator.free(bytes);

        var history = std.array_list.Managed(types.HistoryTurn).init(self.allocator);
        // errdefer frees each appended turn's duped content on error exit
        // (the outer `defer` below only freed the ArrayList storage, not
        // the content strings, so a mid-load OOM leaked every turn parsed
        // so far). On success, toOwnedSlice empties history.items, so the
        // errdefer's item loop runs over zero items and the subsequent
        // defer frees the empty storage -- no double-free either way.
        errdefer for (history.items) |t| {
            self.allocator.free(t.content);
            self.allocator.free(@constCast(t.uuid));
        };
        defer history.deinit();

        var facts = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &facts);

        var decisions = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &decisions);

        var open_tasks = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &open_tasks);

        var file_focus = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &file_focus);

        var outcomes = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &outcomes);

        var pinned_facts = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &pinned_facts);

        var completed_tasks = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &completed_tasks);

        var activated_conditional_skills = std.array_list.Managed([]u8).init(self.allocator);
        errdefer freeArrayListStrings(self.allocator, &activated_conditional_skills);

        var handoff_summary = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(handoff_summary);

        var conversation_summary = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(conversation_summary);

        // sessions-04 origin breadcrumb. Defaults to "" so legacy
        // sessions (and replay sessions that wrote "") load empty. The
        // latest snapshot wins, mirroring conversation_summary above.
        var origin_cwd = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(origin_cwd);

        // sessions-08 consistency reference. The latest snapshot's
        // recorded turn count wins; 0 when no snapshot carried one
        // (legacy / replay snapshots). Scalar, so no alloc dance.
        var message_count_at_snapshot: usize = 0;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var corrupt_line_count: usize = 0;
        var line_number: usize = 0;
        while (lines.next()) |line| {
            line_number += 1;
            if (line.len == 0) continue;

            // Skip corrupt lines instead of failing the entire load. A
            // torn trailing write from a crashed process (see the
            // appendTurn path) or an encrypted record with a mangled
            // auth tag would otherwise make the whole session
            // permanently unreadable. We log the first few skipped
            // lines and continue with the rest of the history.
            const decoded_line = self.decodeRecordLine(line) catch |err| {
                corrupt_line_count += 1;
                if (corrupt_line_count <= 3) {
                    std.log.warn("session: skipping corrupt record in {s} at line {d}: {s}", .{ path, line_number, @errorName(err) });
                }
                continue;
            };
            defer self.allocator.free(decoded_line);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, decoded_line, .{}) catch |err| {
                corrupt_line_count += 1;
                if (corrupt_line_count <= 3) {
                    std.log.warn("session: skipping unparseable record in {s} at line {d}: {s}", .{ path, line_number, @errorName(err) });
                }
                continue;
            };
            defer parsed.deinit();

            const root = parsed.value;
            if (root != .object) continue;
            const obj = root.object;

            const kind = getString(obj, "type") orelse continue;
            if (std.mem.eql(u8, kind, "turn")) {
                const role_str = getString(obj, "role") orelse continue;
                const content = getString(obj, "content") orelse continue;
                const ts = getInteger(obj, "timestamp") orelse clock.nowSeconds();
                // Legacy records (written before the uuid field existed)
                // load with uuid == "". We always dup (even "") so the
                // matching free in LoadedSession.deinit is unconditional
                // and never aliases an empty string literal.
                const turn_uuid = getString(obj, "uuid") orelse "";

                // Reserve the slot first so the final append is infallible;
                // otherwise the duped content/uuid leak when history.append OOMs.
                try history.ensureUnusedCapacity(1);
                const owned_content = try self.allocator.dupe(u8, content);
                errdefer self.allocator.free(owned_content);
                const owned_uuid = try self.allocator.dupe(u8, turn_uuid);
                history.appendAssumeCapacity(.{
                    .role = parseRole(role_str),
                    .content = owned_content,
                    .timestamp = ts,
                    .uuid = owned_uuid,
                });
            } else if (std.mem.eql(u8, kind, "snapshot")) {
                // Two sequential dupes must be guarded so the first is
                // freed if the second OOMs -- previously the first leaked.
                // The `committed` flag disables the errdefer once both
                // dupes have been aliased into conversation_summary /
                // handoff_summary, so the outer function-scope errdefers
                // on those two vars take over and we don't double-free.
                var committed = false;
                const next_conversation_summary = try self.allocator.dupe(u8, getString(obj, "conversation_summary") orelse "");
                errdefer if (!committed) self.allocator.free(next_conversation_summary);
                const next_handoff_summary = try self.allocator.dupe(u8, getString(obj, "handoff_summary") orelse "");
                errdefer if (!committed) self.allocator.free(next_handoff_summary);
                // origin_cwd absent on legacy/pre-breadcrumb snapshots -> "".
                const next_origin_cwd = try self.allocator.dupe(u8, getString(obj, "origin_cwd") orelse "");
                errdefer if (!committed) self.allocator.free(next_origin_cwd);

                self.allocator.free(conversation_summary);
                conversation_summary = next_conversation_summary;
                self.allocator.free(handoff_summary);
                handoff_summary = next_handoff_summary;
                self.allocator.free(origin_cwd);
                origin_cwd = next_origin_cwd;
                committed = true;

                // sessions-08: record the latest snapshot's turn count
                // (absent on legacy snapshots -> leave the prior value).
                if (getInteger(obj, "message_count_at_snapshot")) |n| {
                    message_count_at_snapshot = if (n < 0) 0 else @intCast(n);
                }

                clearArrayListStrings(self.allocator, &facts);
                clearArrayListStrings(self.allocator, &decisions);
                clearArrayListStrings(self.allocator, &open_tasks);
                clearArrayListStrings(self.allocator, &file_focus);
                clearArrayListStrings(self.allocator, &outcomes);
                clearArrayListStrings(self.allocator, &pinned_facts);
                clearArrayListStrings(self.allocator, &completed_tasks);
                clearArrayListStrings(self.allocator, &activated_conditional_skills);

                try copyJsonArrayStrings(self.allocator, obj, "facts", &facts);
                try copyJsonArrayStrings(self.allocator, obj, "decisions", &decisions);
                try copyJsonArrayStrings(self.allocator, obj, "open_tasks", &open_tasks);
                try copyJsonArrayStrings(self.allocator, obj, "file_focus", &file_focus);
                try copyJsonArrayStrings(self.allocator, obj, "recent_tool_outcomes", &outcomes);
                try copyJsonArrayStrings(self.allocator, obj, "pinned_facts", &pinned_facts);
                try copyJsonArrayStrings(self.allocator, obj, "completed_tasks", &completed_tasks);
                try copyJsonArrayStrings(self.allocator, obj, "activated_conditional_skills", &activated_conditional_skills);
            }
        }

        const facts_owned = try arrayListToConstSlice(self.allocator, facts.items);
        errdefer freeStringList(self.allocator, facts_owned);

        const decisions_owned = try arrayListToConstSlice(self.allocator, decisions.items);
        errdefer freeStringList(self.allocator, decisions_owned);

        const open_tasks_owned = try arrayListToConstSlice(self.allocator, open_tasks.items);
        errdefer freeStringList(self.allocator, open_tasks_owned);

        const file_focus_owned = try arrayListToConstSlice(self.allocator, file_focus.items);
        errdefer freeStringList(self.allocator, file_focus_owned);

        const outcomes_owned = try arrayListToConstSlice(self.allocator, outcomes.items);
        errdefer freeStringList(self.allocator, outcomes_owned);

        const pinned_facts_owned = try arrayListToConstSlice(self.allocator, pinned_facts.items);
        errdefer freeStringList(self.allocator, pinned_facts_owned);

        const completed_tasks_owned = try arrayListToConstSlice(self.allocator, completed_tasks.items);
        errdefer freeStringList(self.allocator, completed_tasks_owned);

        const activated_conditional_skills_owned = try arrayListToConstSlice(self.allocator, activated_conditional_skills.items);
        errdefer freeStringList(self.allocator, activated_conditional_skills_owned);

        facts.deinit();
        decisions.deinit();
        open_tasks.deinit();
        file_focus.deinit();
        outcomes.deinit();
        pinned_facts.deinit();
        completed_tasks.deinit();
        activated_conditional_skills.deinit();

        return .{
            .id = try self.allocator.dupe(u8, session_id),
            .history = try history.toOwnedSlice(),
            .snapshot = .{
                .facts = facts_owned,
                .decisions = decisions_owned,
                .open_tasks = open_tasks_owned,
                .file_focus = file_focus_owned,
                .recent_tool_outcomes = outcomes_owned,
                .handoff_summary = handoff_summary,
                .pinned_facts = pinned_facts_owned,
                .completed_tasks = completed_tasks_owned,
                .activated_conditional_skills = activated_conditional_skills_owned,
                .message_count_at_snapshot = message_count_at_snapshot,
            },
            .conversation_summary = conversation_summary,
            .origin_cwd = origin_cwd,
        };
    }

    pub fn list(self: *Store) ![]SessionEntry {
        var dir = try std.Io.Dir.cwd().openDir(rt.io, self.sessions_dir, .{ .iterate = true });
        defer dir.close(rt.io);

        var it = dir.iterate();
        var out = std.array_list.Managed(SessionEntry).init(self.allocator);
        defer out.deinit();

        while (try it.next(rt.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            const id = entry.name[0 .. entry.name.len - ".jsonl".len];
            const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, entry.name });
            defer self.allocator.free(file_path);

            const stat = try std.Io.Dir.cwd().statFile(rt.io, file_path, .{});
            const ts: i64 = @intCast(@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s));

            // Reserve the out slot first so the final append is
            // infallible; otherwise id_owned and label_slice (if non-null)
            // leaked when out.append OOM'd.
            try out.ensureUnusedCapacity(1);
            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            // Best-effort label read: a missing sidecar file is the
            // common case (session has never been renamed), so
            // swallow the error and leave label null.
            const label_slice = self.readLabel(id) catch null;
            // Tags are an opt-in per-session sidecar read; most
            // sessions have none. list() stays cheap by leaving
            // entry.tags empty -- callers that actually need tags
            // call readTags(id) themselves.
            out.appendAssumeCapacity(.{
                .id = id_owned,
                .updated_ts = ts,
                .label = label_slice,
            });
        }

        std.mem.sort(SessionEntry, out.items, {}, lessRecentFirst);
        return out.toOwnedSlice();
    }

    pub fn freeSessionEntries(self: *Store, entries: []SessionEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.id);
            if (entry.label) |label| self.allocator.free(label);
            if (entry.tags.len > 0) self.freeTags(entry.tags);
        }
        self.allocator.free(entries);
    }

    fn tagsPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.tags", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the tag list for `session_id` from its sidecar file.
    /// Returns a heap-allocated slice (possibly empty) when the
    /// sidecar is missing -- callers ALWAYS pair the return with
    /// `freeTags` to keep ownership rules uniform. This matters
    /// because conditional-free based on `len > 0` leaked the
    /// empty-slice alloc in the FileNotFound path.
    pub fn freeTags(self: *Store, tags: [][]u8) void {
        for (tags) |t| self.allocator.free(t);
        self.allocator.free(tags);
    }

    pub fn readTags(self: *Store, session_id: []const u8) ![][]u8 {
        const path = try self.tagsPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return try self.allocator.alloc([]u8, 0),
            else => return err,
        };
        defer self.allocator.free(bytes);

        var out = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (out.items) |item| self.allocator.free(item);
            out.deinit();
        }
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try out.append(try self.allocator.dupe(u8, trimmed));
        }
        return out.toOwnedSlice();
    }

    /// Overwrite the tag list for `session_id`. Empty input deletes
    /// the sidecar file. Each tag is trimmed and whitespace-free
    /// tags are dropped.
    pub fn setTags(self: *Store, session_id: []const u8, tags: []const []const u8) !void {
        const path = try self.tagsPath(session_id);
        defer self.allocator.free(path);

        var rendered = std_io.StringBuilder.init(self.allocator);
        defer rendered.deinit();
        for (tags) |tag| {
            const trimmed = std.mem.trim(u8, tag, " \t\r\n");
            if (trimmed.len == 0) continue;
            try rendered.appendSlice(trimmed);
            try rendered.append('\n');
        }

        if (rendered.items().len == 0) {
            std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        try paths.ensureDir(self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, rendered.items());
    }

    /// Add a tag. Returns true when the tag was appended, false
    /// when it was already present. Tags are case-sensitive to
    /// match how users type them.
    pub fn addTag(self: *Store, session_id: []const u8, tag_raw: []const u8) !bool {
        const trimmed = std.mem.trim(u8, tag_raw, " \t\r\n");
        if (trimmed.len == 0) return false;

        const existing = try self.readTags(session_id);
        defer self.freeTags(existing);
        for (existing) |t| if (std.mem.eql(u8, t, trimmed)) return false;

        var next = std.array_list.Managed([]const u8).init(self.allocator);
        defer next.deinit();
        for (existing) |t| try next.append(t);
        try next.append(trimmed);
        try self.setTags(session_id, next.items);
        return true;
    }

    /// Remove a tag. Returns true when removed, false when it
    /// wasn't present.
    pub fn removeTag(self: *Store, session_id: []const u8, tag_raw: []const u8) !bool {
        const trimmed = std.mem.trim(u8, tag_raw, " \t\r\n");
        if (trimmed.len == 0) return false;

        const existing = try self.readTags(session_id);
        defer self.freeTags(existing);

        var next = std.array_list.Managed([]const u8).init(self.allocator);
        defer next.deinit();
        var removed = false;
        for (existing) |t| {
            if (!removed and std.mem.eql(u8, t, trimmed)) {
                removed = true;
                continue;
            }
            try next.append(t);
        }
        if (!removed) return false;
        try self.setTags(session_id, next.items);
        return true;
    }

    /// Return the path to the sidecar label file for `session_id`.
    /// Caller owns the returned slice.
    fn labelPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.label", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the human-readable label for `session_id` from the
    /// sidecar file `<sessions_dir>/<session_id>.label`. Returns
    /// null when the sidecar is missing (common case -- sessions
    /// start without a label). Caller owns the returned slice.
    pub fn readLabel(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.labelPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        // Trim trailing whitespace so a newline at the end of an
        // editor-edited file doesn't pollute the rendered label.
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) {
            self.allocator.free(bytes);
            return null;
        }
        if (trimmed.len == bytes.len) return bytes;
        const copy = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(bytes);
        return copy;
    }

    /// Write `label` to the sidecar file for `session_id`. Passing
    /// an empty label deletes the sidecar file (equivalent to
    /// clearing the label). The sessions directory is created if it
    /// does not already exist.
    pub fn setLabel(self: *Store, session_id: []const u8, label: []const u8) !void {
        const path = try self.labelPath(session_id);
        defer self.allocator.free(path);

        const trimmed = std.mem.trim(u8, label, " \t\r\n");
        if (trimmed.len == 0) {
            std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        try paths.ensureDir(self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, trimmed);
    }

    /// Return the path to the AI-title sidecar file for `session_id`.
    /// Caller owns the returned slice. The AI title lives in a distinct
    /// `<id>.aititle` sidecar (Phase 11 sessions-06) so it never collides
    /// with a user-set `.label` -- this is what lets a `/rename` always win.
    fn aiTitlePath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.aititle", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the AI-generated title for `session_id` from the sidecar file
    /// `<sessions_dir>/<session_id>.aititle`. Returns null when the sidecar
    /// is missing (common case -- a title is generated best-effort after the
    /// first turn and may never exist offline). Caller owns the returned slice.
    pub fn readAiTitle(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.aiTitlePath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        if (trimmed.len == 0) {
            self.allocator.free(bytes);
            return null;
        }
        if (trimmed.len == bytes.len) return bytes;
        const copy = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(bytes);
        return copy;
    }

    /// Write `title` to the AI-title sidecar for `session_id`. Passing an
    /// empty title deletes the sidecar. Newlines are stripped (the caller's
    /// title parser already does this, but guard here too) so a stray
    /// newline cannot corrupt a TSV `/session list` row. The sessions
    /// directory is created if it does not already exist.
    pub fn setAiTitle(self: *Store, session_id: []const u8, title: []const u8) !void {
        const path = try self.aiTitlePath(session_id);
        defer self.allocator.free(path);

        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len == 0) {
            std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        // Replace any embedded line terminators with spaces so the title is
        // always single-line on disk.
        var safe = std_io.StringBuilder.init(self.allocator);
        defer safe.deinit();
        for (trimmed) |ch| {
            if (ch == '\n' or ch == '\r') {
                try safe.append(' ');
            } else {
                try safe.append(ch);
            }
        }

        try paths.ensureDir(self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, safe.items());
    }

    // ── Session metadata sidecars (Phase 11 sessions-07) ──────────────
    // git branch / first prompt / PR links live in distinct sidecar
    // files next to the session jsonl, mirroring the .label / .tags /
    // .aititle pattern so the JSONL record schema stays stable (no
    // migration). All writes go through writeSidecarAtomic so a reader
    // never sees a torn file, and all sidecars are 0o600.

    /// Return the path to the git-branch sidecar (`<id>.branch`).
    /// Caller owns the returned slice.
    fn branchPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.branch", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the persisted git branch for `session_id`. Returns null when
    /// the sidecar is missing (session not on a branch, or pre-feature).
    /// Caller owns the returned slice.
    pub fn readBranch(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.branchPath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 1024);
    }

    /// Persist the git branch for `session_id`. Empty input deletes the
    /// sidecar. Embedded newlines are replaced with spaces so the value
    /// stays single-line (it feeds TSV `/session list` rows).
    pub fn setBranch(self: *Store, session_id: []const u8, branch: []const u8) !void {
        const path = try self.branchPath(session_id);
        defer self.allocator.free(path);
        try self.writeSingleLineSidecar(path, branch);
    }

    /// Return the path to the session-mode sidecar (`<id>.mode`).
    /// Caller owns the returned slice.
    fn modePath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.mode", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the persisted session mode for `session_id` (e.g. "coordinator" or
    /// "normal"). Returns null when the sidecar is missing (pre-feature, or a
    /// session that never recorded a mode). Caller owns the returned slice.
    /// Used by the resume path to reconcile coordinator mode (remote-server-01).
    pub fn readMode(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.modePath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 256);
    }

    /// Persist the session mode for `session_id`. Empty input deletes the
    /// sidecar. Mirrors the `.branch` / `.label` sidecar pattern so the JSONL
    /// record schema stays stable.
    pub fn setMode(self: *Store, session_id: []const u8, mode: []const u8) !void {
        const path = try self.modePath(session_id);
        defer self.allocator.free(path);
        try self.writeSingleLineSidecar(path, mode);
    }

    /// Return the path to the prompt-bar accent color sidecar (`<id>.color`).
    /// Caller owns the returned slice.
    fn colorPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.color", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the persisted prompt-bar accent color for `session_id`
    /// (commands-sweep-03). Returns null when the sidecar is missing
    /// (default color). Caller owns the returned slice.
    pub fn readColor(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.colorPath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 64);
    }

    /// Persist the prompt-bar accent color for `session_id`. Empty input
    /// deletes the sidecar (resets to the default color). Mirrors the
    /// `.branch` / `.mode` sidecar pattern so the JSONL record schema stays
    /// stable.
    pub fn setColor(self: *Store, session_id: []const u8, color: []const u8) !void {
        const path = try self.colorPath(session_id);
        defer self.allocator.free(path);
        try self.writeSingleLineSidecar(path, color);
    }

    /// Return the path to the first-prompt sidecar (`<id>.firstprompt`).
    /// Caller owns the returned slice.
    fn firstPromptPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.firstprompt", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the persisted first user prompt for `session_id`. Returns null
    /// when absent. Caller owns the returned slice.
    pub fn readFirstPrompt(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.firstPromptPath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 16 * 1024);
    }

    /// Persist the first user prompt for `session_id` ONLY if no first-prompt
    /// sidecar exists yet. Returns true when it wrote, false when one was
    /// already present (write-once). Embedded newlines are replaced with
    /// spaces so the preview stays single-line. An empty/whitespace prompt
    /// is ignored (returns false).
    pub fn setFirstPromptIfAbsent(self: *Store, session_id: []const u8, prompt: []const u8) !bool {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed.len == 0) return false;

        const path = try self.firstPromptPath(session_id);
        defer self.allocator.free(path);

        // Existence check: a torn/empty file counts as absent and will be
        // overwritten, which is the desired self-heal.
        if (readTrimmedSidecar(self.allocator, path, 16 * 1024)) |existing| {
            if (existing) |e| {
                self.allocator.free(e);
                return false;
            }
        } else |_| {}

        try self.writeSingleLineSidecar(path, trimmed);
        return true;
    }

    /// Return the path to the PR-links sidecar (`<id>.prlinks`).
    /// Caller owns the returned slice.
    fn prLinksPath(self: *Store, session_id: []const u8) ![]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.prlinks", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Read the PR links for `session_id` (one per line). Returns a
    /// heap-allocated slice (possibly empty when the sidecar is missing).
    /// Callers ALWAYS pair the return with `freeTags` to keep ownership
    /// uniform (same shape/free rule as readTags).
    pub fn readPrLinks(self: *Store, session_id: []const u8) ![][]u8 {
        const path = try self.prLinksPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return try self.allocator.alloc([]u8, 0),
            else => return err,
        };
        defer self.allocator.free(bytes);

        var out = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (out.items) |item| self.allocator.free(item);
            out.deinit();
        }
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            try out.append(try self.allocator.dupe(u8, trimmed));
        }
        return out.toOwnedSlice();
    }

    /// Append a PR link to `session_id` (newline-delimited, deduped).
    /// Returns true when appended, false when the link was already present
    /// or empty. Mirrors addTag's read-dedup-rewrite shape.
    pub fn addPrLink(self: *Store, session_id: []const u8, url_raw: []const u8) !bool {
        const trimmed = std.mem.trim(u8, url_raw, " \t\r\n");
        if (trimmed.len == 0) return false;

        const existing = try self.readPrLinks(session_id);
        defer self.freeTags(existing);
        for (existing) |e| if (std.mem.eql(u8, e, trimmed)) return false;

        const path = try self.prLinksPath(session_id);
        defer self.allocator.free(path);

        var rendered = std_io.StringBuilder.init(self.allocator);
        defer rendered.deinit();
        for (existing) |e| {
            try rendered.appendSlice(e);
            try rendered.append('\n');
        }
        try rendered.appendSlice(trimmed);
        try rendered.append('\n');

        try paths.ensureDir(self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, rendered.items());
        return true;
    }

    /// Shared single-line sidecar write: trims, deletes the file when the
    /// trimmed value is empty, and replaces embedded line terminators with
    /// spaces so the persisted value never spans rows. Used by setBranch /
    /// setFirstPromptIfAbsent.
    fn writeSingleLineSidecar(self: *Store, path: []const u8, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) {
            std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            return;
        }

        var safe = std_io.StringBuilder.init(self.allocator);
        defer safe.deinit();
        for (trimmed) |ch| {
            if (ch == '\n' or ch == '\r') {
                try safe.append(' ');
            } else {
                try safe.append(ch);
            }
        }

        try paths.ensureDir(self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, safe.items());
    }

    /// Resolve the title to display for `session_id` with user-rename
    /// precedence (Phase 11 sessions-06): a user-set `.label` (via /rename)
    /// always wins; otherwise the AI-generated `.aititle`; otherwise the raw
    /// id. The returned slice is ALWAYS freshly allocated (even in the id
    /// fallback), so the caller frees it uniformly without tracking which
    /// branch produced it.
    pub fn currentTitle(self: *Store, session_id: []const u8) ![]u8 {
        if (try self.readLabel(session_id)) |label| return label;
        if (try self.readAiTitle(session_id)) |ai| return ai;
        return self.allocator.dupe(u8, session_id);
    }

    /// Result of a cleanup pass: how many session files were deleted
    /// and how many failed to delete (file system error, race, etc).
    /// Mirrors claude-code-main/src/utils/cleanup.ts CleanupResult.
    pub const CleanupResult = struct {
        deleted: usize = 0,
        errors: usize = 0,
    };

    /// Delete session files older than `retention_days` based on
    /// mtime. Returns the number of files removed and any errors
    /// encountered. retention_days = 0 disables cleanup (no-op) so
    /// the caller can wire this up unconditionally and let the user
    /// opt in via config. Ported from cleanup.ts cleanupOldSessionFiles
    /// -- the reference walks a per-project directory tree, but
    /// zcode stores everything in a flat sessions_dir so we only
    /// need one readdir loop.
    pub fn cleanupOldSessions(self: *Store, retention_days: u32) !CleanupResult {
        if (retention_days == 0) return .{};

        const days_ns: i128 = @as(i128, retention_days) * @as(i128, std.time.ns_per_s) * 24 * 60 * 60;
        const cutoff_ns: i128 = clock.nowNanos() - days_ns;

        var dir = std.Io.Dir.cwd().openDir(rt.io, self.sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        defer dir.close(rt.io);

        var result: CleanupResult = .{};
        var it = dir.iterate();
        while (try it.next(rt.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            const file_path = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, entry.name });
            defer self.allocator.free(file_path);

            const stat = std.Io.Dir.cwd().statFile(rt.io, file_path, .{}) catch {
                result.errors += 1;
                continue;
            };
            if (stat.mtime.toNanoseconds() >= cutoff_ns) continue;

            std.Io.Dir.cwd().deleteFile(rt.io, file_path) catch {
                result.errors += 1;
                continue;
            };
            result.deleted += 1;
        }
        return result;
    }

    fn appendRecordLine(self: *Store, file: std.Io.File, record_json: []const u8) !void {
        // Escape U+2028/U+2029 so a prompt or tool output that
        // contains those Unicode line terminators doesn't break
        // external tools that split the .jsonl file by ECMA-262
        // line-terminator semantics. parse_helpers.ndjsonSafeEscape
        // short-circuits to a simple dupe when there's nothing to
        // replace so the common case still pays one copy.
        const safe = try parse_helpers.ndjsonSafeEscape(self.allocator, record_json);
        defer self.allocator.free(safe);

        if (self.encryption_key) |key| {
            const encrypted = try encryptRecord(self.allocator, key, safe);
            defer self.allocator.free(encrypted);
            try file.writeStreamingAll(rt.io, encrypted);
            try file.writeStreamingAll(rt.io, "\n");
            return;
        }

        try file.writeStreamingAll(rt.io, safe);
        try file.writeStreamingAll(rt.io, "\n");
    }

    fn decodeRecordLine(self: *Store, line: []const u8) ![]u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            // Backward compatibility: keep non-JSON lines as-is.
            return self.allocator.dupe(u8, line);
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return self.allocator.dupe(u8, line);
        }

        const obj = parsed.value.object;
        const kind = getString(obj, "type") orelse return self.allocator.dupe(u8, line);
        if (!std.mem.eql(u8, kind, encrypted_record_type)) {
            return self.allocator.dupe(u8, line);
        }

        const key = self.encryption_key orelse return error.SessionKeyRequired;
        const nonce_hex = getString(obj, "nonce") orelse return error.InvalidEncryptedRecord;
        const tag_hex = getString(obj, "tag") orelse return error.InvalidEncryptedRecord;
        const cipher_hex = getString(obj, "ciphertext") orelse return error.InvalidEncryptedRecord;
        return decryptRecord(self.allocator, key, nonce_hex, tag_hex, cipher_hex);
    }

    pub const TurnCounts = struct {
        total: usize = 0,
        user: usize = 0,
        assistant: usize = 0,
        bytes: u64 = 0,
    };

    /// Coarse turn counts for `session_id`, derived by scanning the
    /// jsonl file for the `"type":"turn"` / `"role":"..."` markers.
    /// Used by stats_report for /stats and /insights. Keeps file
    /// access inside the Store so callers never read the raw jsonl.
    pub fn countTurns(self: *Store, session_id: []const u8) !TurnCounts {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return TurnCounts{},
            else => return err,
        };
        defer self.allocator.free(bytes);

        var counts = TurnCounts{ .bytes = bytes.len };
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, "\"type\":\"turn\"") == null) continue;
            counts.total += 1;
            if (std.mem.indexOf(u8, trimmed, "\"role\":\"user\"") != null) {
                counts.user += 1;
            } else if (std.mem.indexOf(u8, trimmed, "\"role\":\"assistant\"") != null) {
                counts.assistant += 1;
            }
        }
        return counts;
    }

    pub fn sessionPath(self: *Store, session_id: []const u8) ![]u8 {
        try validateSessionId(session_id);
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.jsonl", .{session_id});
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
    }

    /// Remove the turn record whose `uuid` matches `turn_uuid` from the
    /// session JSONL, rewriting the file atomically (temp + rename) so a
    /// crash mid-rewrite cannot leave a torn file (sessions-08). Only
    /// `"type":"turn"` records are candidates; snapshot / metadata
    /// records and any non-turn lines are always preserved. Returns the
    /// number of turn records removed (0 when no turn carried that uuid).
    ///
    /// This is the orphan-cleanup primitive a code-restoring rewind
    /// (sessions-01) uses to drop the now-orphaned turns from the
    /// append-only log so the next resume does not replay them.
    ///
    /// Encrypted records are decoded to inspect their uuid, then the
    /// surviving records are re-encoded (and re-encrypted under the same
    /// key) through the normal append path -- the file stays in the same
    /// on-disk format it started in.
    ///
    /// Concurrency: like the sidecar writers, this assumes a single
    /// writer per session. Two zcode processes rewriting one session
    /// file concurrently is already unsupported.
    pub fn removeTurnByUuid(self: *Store, session_id: []const u8, turn_uuid: []const u8) !usize {
        if (turn_uuid.len == 0) return 0;

        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer self.allocator.free(bytes);

        // Re-encode the survivors into a fresh buffer, line by line. We
        // keep the decoded plaintext of each non-removed record and feed
        // it back through the same escape + (optional) encrypt path the
        // append uses, so the rewritten file is byte-for-byte a valid
        // store file in the same format.
        var rewritten = std_io.StringBuilder.init(self.allocator);
        defer rewritten.deinit();

        var removed: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const decoded = self.decodeRecordLine(line) catch {
                // Corrupt line: preserve it verbatim rather than dropping
                // data we cannot interpret. It round-trips unchanged.
                try self.appendRecordPlaintext(&rewritten, line, true);
                continue;
            };
            defer self.allocator.free(decoded);

            // Decide whether this decoded record is the turn to drop.
            if (self.recordMatchesTurnUuid(decoded, turn_uuid)) {
                removed += 1;
                continue;
            }

            try self.appendRecordPlaintext(&rewritten, decoded, false);
        }

        if (removed == 0) return 0;

        try writeJsonlAtomic(self.allocator, path, rewritten.items());
        return removed;
    }

    /// True when `decoded` is a `"type":"turn"` record whose `uuid`
    /// field equals `turn_uuid`. Parse failures / non-objects / non-turn
    /// records are never a match (so they survive the rewrite).
    fn recordMatchesTurnUuid(self: *Store, decoded: []const u8, turn_uuid: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, decoded, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const obj = parsed.value.object;
        const kind = getString(obj, "type") orelse return false;
        if (!std.mem.eql(u8, kind, "turn")) return false;
        const rec_uuid = getString(obj, "uuid") orelse return false;
        return std.mem.eql(u8, rec_uuid, turn_uuid);
    }

    /// Append one already-decoded record (`plaintext`) plus a trailing
    /// newline to `out`, applying the same NDJSON escape + optional
    /// encryption the live append path uses. When `verbatim` is true the
    /// line is a record we could not decode (corrupt); we copy it as-is
    /// without re-escaping or re-encrypting so its bytes survive intact.
    fn appendRecordPlaintext(self: *Store, out: *std_io.StringBuilder, plaintext: []const u8, verbatim: bool) !void {
        if (verbatim) {
            try out.writer().writeAll(plaintext);
            try out.writer().writeAll("\n");
            return;
        }

        const safe = try parse_helpers.ndjsonSafeEscape(self.allocator, plaintext);
        defer self.allocator.free(safe);

        if (self.encryption_key) |key| {
            const encrypted = try encryptRecord(self.allocator, key, safe);
            defer self.allocator.free(encrypted);
            try out.writer().writeAll(encrypted);
            try out.writer().writeAll("\n");
            return;
        }

        try out.writer().writeAll(safe);
        try out.writer().writeAll("\n");
    }

    pub const ConsistencyReport = struct {
        /// Whether the loaded turn count diverges from the latest
        /// snapshot's recorded count beyond tolerance.
        has_drift: bool = false,
        /// Number of turns the loaded history actually contains.
        loaded_count: usize = 0,
        /// The snapshot's recorded turn count, or 0 when no snapshot
        /// carried one (in which case the check is skipped, has_drift
        /// stays false).
        expected_count: usize = 0,
    };

    /// Compare the count of loaded turns against the turn count recorded
    /// in the session's latest snapshot (sessions-08). Drift means a
    /// rewind (or a torn write) left the on-disk history out of sync with
    /// the snapshot's recorded position. This is non-fatal: the reference
    /// only logs drift, so callers `std.log.warn` and continue. When the
    /// snapshot recorded no count (legacy / replay snapshot, count == 0),
    /// the check is skipped and no drift is reported.
    pub fn checkResumeConsistency(loaded: *const LoadedSession) ConsistencyReport {
        const expected = loaded.snapshot.message_count_at_snapshot;
        if (expected == 0) {
            return .{ .has_drift = false, .loaded_count = loaded.history.len, .expected_count = 0 };
        }
        return .{
            .has_drift = loaded.history.len != expected,
            .loaded_count = loaded.history.len,
            .expected_count = expected,
        };
    }
};

/// Write `bytes` to `target` via a sibling .tmp + rename so a SIGINT
/// or `kill -9` between createFile and writeAll can't leave a
/// truncated sidecar for a reader to interpret mid-update. The
/// tmp path lives next to target so the rename is inode-cheap and
/// crosses no filesystem boundary.
fn writeSidecarAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(tmp_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {}; // best-effort durability
    }
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

/// Atomically replace the session JSONL at `target` with `bytes`
/// (sessions-08 removeTurnByUuid rewrite). Same temp + rename discipline
/// and 0o600 mode as the sidecar writer; kept distinct so its intent
/// (rewriting the conversation log, not a sidecar) reads clearly at the
/// call site.
fn writeJsonlAtomic(allocator: std.mem.Allocator, target: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.rewrite.tmp", .{target});
    defer allocator.free(tmp_path);
    {
        const file = try std.Io.Dir.cwd().createFile(rt.io, tmp_path, .{ .truncate = true, .permissions = std.Io.File.Permissions.fromMode(0o600) });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, bytes);
        file.sync(rt.io) catch {}; // best-effort durability
    }
    errdefer std.Io.Dir.cwd().deleteFile(rt.io, tmp_path) catch {};
    try std.Io.Dir.renameAbsolute(tmp_path, target, rt.io);
}

/// Read a single-value sidecar at `path`, trim surrounding whitespace, and
/// return null when the file is missing or trims to empty. Mirrors the
/// trim-and-shrink dance in readLabel/readAiTitle so the branch and
/// first-prompt readers share one implementation. Caller owns the slice.
fn readTrimmedSidecar(allocator: std.mem.Allocator, path: []const u8, limit: usize) !?[]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, allocator, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(bytes);
        return null;
    }
    if (trimmed.len == bytes.len) return bytes;
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(bytes);
    return copy;
}

/// Open `path` for appending. On POSIX we use O_APPEND so concurrent writers
/// from two zcode processes on the same session file cannot interleave bytes
/// (each write() is atomic up to PIPE_BUF on POSIX). On Windows we fall back
/// to createFile + seekFromEnd; it is still best-effort there.
fn openAppendFile(path: []const u8) !std.Io.File {
    if (@import("builtin").os.tag == .windows) {
        const file = try std.Io.Dir.cwd().createFile(rt.io, path, .{ .read = true, .truncate = false });
        errdefer file.close(rt.io);
        // 0.16: no seek; subsequent writes go positional
        return file;
    }

    const flags: std.posix.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    };
    const fd = try std_io.openFlagsAlloc(rt.gpa, path, flags, 0o600);
    return std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Reject session IDs that could escape the sessions directory. Only permit
/// alphanumerics, `-`, `_`, `.`, and `:` (used by some bundle IDs). Leading
/// `.` is also rejected to avoid hidden files and `..` traversal.
pub fn validateSessionId(session_id: []const u8) !void {
    if (session_id.len == 0 or session_id.len > 256) return error.InvalidSessionId;
    if (session_id[0] == '.') return error.InvalidSessionId;
    for (session_id) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '_' or ch == '.' or ch == ':';
        if (!ok) return error.InvalidSessionId;
    }
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn loadSessionKey(allocator: std.mem.Allocator, required: bool) !?[Aes256Gcm.key_length]u8 {
    // Precedence:
    //   1. ZCODE_SESSION_KEY (env) - explicit operator-supplied key,
    //      lets CI and headless setups drive encryption without a
    //      keychain round-trip.
    //   2. OS keychain entry - durable per-install key, provisioned
    //      once per machine and reused across runs.
    //   3. Auto-generate and store in keychain (only when
    //      encryption is required); keeps the default-on experience
    //      working on fresh installs with no operator action.
    if (@import("../core/env.zig").getenv(session_key_env)) |raw_ptr| {
        const raw = std.mem.trim(u8, raw_ptr, " \t\r\n");
        if (raw.len > 0) {
            return @as(?[Aes256Gcm.key_length]u8, try parseSessionKey(raw));
        }
    }

    if (keychain.get(allocator, session_keychain_account)) |raw_key| {
        defer allocator.free(raw_key);
        const parsed = parseSessionKey(raw_key) catch {
            if (required) return error.InvalidSessionKey;
            return null;
        };
        return @as(?[Aes256Gcm.key_length]u8, parsed);
    } else |_| {}

    if (!required) return null;

    // Auto-generate on first run so default-on encryption is
    // frictionless. Persistence MUST succeed: otherwise the next
    // run generates a different key and every session written
    // during this run becomes permanently undecryptable. The
    // keychain module already falls back to a ChaCha20-Poly1305
    // file store when the OS keychain is unavailable, so failure
    // here means the filesystem itself refused the write (read-
    // only mount, no home dir, EACCES). Fail closed so the
    // operator can fix the substrate, set ZCODE_SESSION_KEY
    // explicitly, or disable encryption before any session data
    // is written under a key we cannot recover.
    var fresh: [Aes256Gcm.key_length]u8 = undefined;
    rng.secureBytes(&fresh);
    storeKeyInKeychain(allocator, fresh) catch |err| {
        std.log.err(
            "session: failed to persist auto-generated session key ({s}); refusing to encrypt sessions with an ephemeral key. Set ZCODE_SESSION_KEY explicitly or disable session encryption.",
            .{@errorName(err)},
        );
        return error.SessionKeyPersistFailed;
    };
    return @as(?[Aes256Gcm.key_length]u8, fresh);
}

fn storeKeyInKeychain(allocator: std.mem.Allocator, key: [Aes256Gcm.key_length]u8) !void {
    const alphabet = "0123456789abcdef";
    var hex_buf: [Aes256Gcm.key_length * 2]u8 = undefined;
    for (key, 0..) |b, i| {
        hex_buf[i * 2] = alphabet[@as(usize, b >> 4)];
        hex_buf[i * 2 + 1] = alphabet[@as(usize, b & 0x0f)];
    }
    try keychain.set(allocator, session_keychain_account, &hex_buf);
}

fn parseSessionKey(raw: []const u8) ![Aes256Gcm.key_length]u8 {
    const key = blk: {
        if (std.mem.startsWith(u8, raw, "hex:")) break :blk try parseHexKey(raw["hex:".len..]);
        if (std.mem.startsWith(u8, raw, "base64:")) break :blk try parseBase64Key(raw["base64:".len..]);
        if (raw.len == Aes256Gcm.key_length * 2) break :blk try parseHexKey(raw);
        break :blk try parseBase64Key(raw);
    };

    // Reject obviously weak keys. An all-zero key means "someone typed
    // 0000... to silence the require-key check" or "the env var was
    // truncated by a misconfigured secret store". Session AES-GCM
    // encryption with a zero key is effectively no encryption, and
    // the user sees "encryption enabled" in status/config. Fail hard
    // so the operator fixes the misconfiguration before any session
    // record is written to disk.
    var all_zero = true;
    for (key) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return error.InvalidSessionKey;

    return key;
}

fn parseHexKey(hex: []const u8) ![Aes256Gcm.key_length]u8 {
    var out: [Aes256Gcm.key_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidSessionKey;
    return out;
}

fn parseBase64Key(encoded: []const u8) ![Aes256Gcm.key_length]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidSessionKey;
    if (decoded_len != Aes256Gcm.key_length) return error.InvalidSessionKey;

    var out: [Aes256Gcm.key_length]u8 = undefined;
    std.base64.standard.Decoder.decode(out[0..], encoded) catch return error.InvalidSessionKey;
    return out;
}

fn encryptRecord(allocator: std.mem.Allocator, key: [Aes256Gcm.key_length]u8, plaintext: []const u8) ![]u8 {
    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    rng.secureBytes(&nonce);

    const ciphertext = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(ciphertext);

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(ciphertext, &tag, plaintext, "", nonce, key);

    const nonce_hex = try hexEncodeAlloc(allocator, nonce[0..]);
    defer allocator.free(nonce_hex);
    const tag_hex = try hexEncodeAlloc(allocator, tag[0..]);
    defer allocator.free(tag_hex);
    const cipher_hex = try hexEncodeAlloc(allocator, ciphertext);
    defer allocator.free(cipher_hex);

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(.{
        .type = encrypted_record_type,
        .alg = "aes-256-gcm",
        .nonce = nonce_hex,
        .tag = tag_hex,
        .ciphertext = cipher_hex,
    }, .{})});
    return out.toOwnedSlice();
}

fn decryptRecord(
    allocator: std.mem.Allocator,
    key: [Aes256Gcm.key_length]u8,
    nonce_hex: []const u8,
    tag_hex: []const u8,
    cipher_hex: []const u8,
) ![]u8 {
    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&nonce, nonce_hex) catch return error.InvalidEncryptedRecord;

    var tag: [Aes256Gcm.tag_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&tag, tag_hex) catch return error.InvalidEncryptedRecord;

    const ciphertext = try hexDecodeAlloc(allocator, cipher_hex);
    defer allocator.free(ciphertext);

    const plaintext = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plaintext);
    Aes256Gcm.decrypt(plaintext, ciphertext, tag, "", nonce, key) catch return error.InvalidEncryptedRecord;
    return plaintext;
}

fn hexEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const alphabet = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(out);
    for (bytes, 0..) |b, idx| {
        out[idx * 2] = alphabet[@as(usize, b >> 4)];
        out[idx * 2 + 1] = alphabet[@as(usize, b & 0x0f)];
    }
    return out;
}

fn hexDecodeAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidEncryptedRecord;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, hex) catch return error.InvalidEncryptedRecord;
    return out;
}

fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

fn parseRole(role: []const u8) types.HistoryRole {
    if (std.mem.eql(u8, role, "assistant")) return .assistant;
    if (std.mem.eql(u8, role, "system")) return .system;
    if (std.mem.eql(u8, role, "tool")) return .tool;
    return .user;
}

fn copyJsonArrayStrings(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, out: *std.array_list.Managed([]u8)) !void {
    const v = obj.get(key) orelse return;
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .string) continue;
        const duped = try allocator.dupe(u8, item.string);
        out.append(duped) catch |err| {
            allocator.free(duped);
            return err;
        };
    }
}

fn arrayListToConstSlice(allocator: std.mem.Allocator, input: []const []u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, input.len);
    for (input, 0..) |item, idx| {
        out[idx] = item;
    }
    return out;
}

fn clearArrayListStrings(allocator: std.mem.Allocator, arr: *std.array_list.Managed([]u8)) void {
    for (arr.items) |item| allocator.free(item);
    arr.clearRetainingCapacity();
}

fn freeArrayListStrings(allocator: std.mem.Allocator, arr: *std.array_list.Managed([]u8)) void {
    clearArrayListStrings(allocator, arr);
    arr.deinit();
}

const freeStringList = @import("../core/parse_helpers.zig").freeStringSlice;

fn lessRecentFirst(_: void, a: SessionEntry, b: SessionEntry) bool {
    return a.updated_ts > b.updated_ts;
}

pub fn emptySnapshot() types.SessionSnapshot {
    return .{
        .facts = &.{},
        .decisions = &.{},
        .open_tasks = &.{},
        .file_focus = &.{},
        .recent_tool_outcomes = &.{},
        .handoff_summary = "",
        .pinned_facts = &.{},
        .completed_tasks = &.{},
        .activated_conditional_skills = &.{},
    };
}

const testing = std.testing;

test "parse role" {
    try testing.expect(parseRole("assistant") == .assistant);
    try testing.expect(parseRole("user") == .user);
}

test "parseSessionKey rejects all-zero keys" {
    // 64 hex zeros -> 32 bytes of zero.
    const all_zero_hex = "0" ** 64;
    try testing.expectError(error.InvalidSessionKey, parseSessionKey(all_zero_hex));
    // Explicit hex: prefix.
    try testing.expectError(error.InvalidSessionKey, parseSessionKey("hex:" ++ all_zero_hex));
    // base64 of 32 zero bytes = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".
    try testing.expectError(error.InvalidSessionKey, parseSessionKey("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
}

test "parse session key from hex and base64" {
    const key_hex =
        "0011223344556677" ++
        "8899aabbccddeeff" ++
        "0011223344556677" ++
        "8899aabbccddeeff";
    const from_hex = try parseSessionKey(key_hex);
    try testing.expectEqual(@as(u8, 0x00), from_hex[0]);
    try testing.expectEqual(@as(u8, 0xff), from_hex[15]);

    const key_b64 =
        "ABEiM0RVZneImaq7" ++
        "zN3u/wARIjNEVWZ3" ++
        "iJmqu8zd7v8=";
    const from_b64 = try parseSessionKey(key_b64);
    try testing.expectEqual(@as(u8, 0x00), from_b64[0]);
    try testing.expectEqual(@as(u8, 0xff), from_b64[31]);
}

test "encrypted record roundtrip" {
    const allocator = testing.allocator;
    const key = try parseSessionKey(
        "0011223344556677" ++
            "8899aabbccddeeff" ++
            "0011223344556677" ++
            "8899aabbccddeeff",
    );

    const plain = "{\"type\":\"turn\",\"role\":\"user\",\"content\":\"hi\"}";
    const encrypted = try encryptRecord(allocator, key, plain);
    defer allocator.free(encrypted);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encrypted, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try testing.expect(std.mem.eql(u8, getString(obj, "type") orelse "", encrypted_record_type));

    const decrypted = try decryptRecord(
        allocator,
        key,
        getString(obj, "nonce") orelse return error.TestUnexpectedResult,
        getString(obj, "tag") orelse return error.TestUnexpectedResult,
        getString(obj, "ciphertext") orelse return error.TestUnexpectedResult,
    );
    defer allocator.free(decrypted);
    try testing.expectEqualStrings(plain, decrypted);
}

test "createSessionId produces unique, well-formed ids" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const a = try store.createSessionId();
    defer testing.allocator.free(a);
    const b = try store.createSessionId();
    defer testing.allocator.free(b);

    // Two ids created back-to-back should differ in the 128-bit nonce
    // even when they share a timestamp.
    try testing.expect(!std.mem.eql(u8, a, b));

    // Format is "<timestamp>-<32 hex chars>".
    const dash = std.mem.indexOfScalar(u8, a, '-') orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 32), a.len - dash - 1);
    for (a[dash + 1 ..]) |c| try testing.expect(std.ascii.isHex(c));
}

test "appendTurn persists an explicit uuid that load reads back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const known = "11112222-3333-4444-5555-666677778888";
    try store.appendTurn("sess-uuid", .user, "hello there", known);

    var loaded = try store.load("sess-uuid");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("hello there", loaded.history[0].content);
    try testing.expectEqualStrings(known, loaded.history[0].uuid);
}

test "appendTurn with empty uuid mints a non-empty uuid on disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-mint", .assistant, "auto id", "");

    var loaded = try store.load("sess-mint");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    // A fresh canonical uuid was minted (36 chars, dashed) even though the
    // caller passed "".
    try testing.expectEqual(@as(usize, 36), loaded.history[0].uuid.len);
}

test "load tolerates a legacy turn record with no uuid field" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // A record written before the uuid field existed: no "uuid" key.
    const legacy = "{\"type\":\"turn\",\"role\":\"user\",\"content\":\"legacy\",\"timestamp\":42}\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "legacy.jsonl", .data = legacy });

    var loaded = try store.load("legacy");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("legacy", loaded.history[0].content);
    // Missing uuid defaults to "" and does not crash on free.
    try testing.expectEqualStrings("", loaded.history[0].uuid);
}

test "appendSnapshot persists origin_cwd and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const snapshot = emptySnapshot();
    try store.appendSnapshot("sess-origin", &snapshot, "summary", "/Users/dev/project");

    var loaded = try store.load("sess-origin");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("/Users/dev/project", loaded.origin_cwd);
}

test "load defaults origin_cwd to empty for a legacy snapshot record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // A snapshot record written before the origin_cwd breadcrumb existed.
    const legacy = "{\"type\":\"snapshot\",\"conversation_summary\":\"old\",\"timestamp\":7}\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "legacy-snap.jsonl", .data = legacy });

    var loaded = try store.load("legacy-snap");
    defer loaded.deinit(testing.allocator);

    // Missing origin_cwd defaults to "" and does not crash on free.
    try testing.expectEqualStrings("", loaded.origin_cwd);
}

test "appendSnapshot with empty origin_cwd round-trips as empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const snapshot = emptySnapshot();
    // Replay/CLI sites pass "" -- the breadcrumb stays empty.
    try store.appendSnapshot("sess-empty-origin", &snapshot, "summary", "");

    var loaded = try store.load("sess-empty-origin");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("", loaded.origin_cwd);
}

test "removeTurnByUuid drops the matching middle turn and keeps the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const a = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
    const b = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";
    const c = "cccccccc-cccc-cccc-cccc-cccccccccccc";
    try store.appendTurn("sess-rm", .user, "first", a);
    try store.appendTurn("sess-rm", .assistant, "second", b);
    try store.appendTurn("sess-rm", .user, "third", c);

    const removed = try store.removeTurnByUuid("sess-rm", b);
    try testing.expectEqual(@as(usize, 1), removed);

    var loaded = try store.load("sess-rm");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), loaded.history.len);
    try testing.expectEqualStrings("first", loaded.history[0].content);
    try testing.expectEqualStrings(a, loaded.history[0].uuid);
    try testing.expectEqualStrings("third", loaded.history[1].content);
    try testing.expectEqualStrings(c, loaded.history[1].uuid);
}

test "removeTurnByUuid returns 0 when no turn carries the uuid" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const a = "11111111-1111-1111-1111-111111111111";
    try store.appendTurn("sess-rm-miss", .user, "only", a);

    const removed = try store.removeTurnByUuid("sess-rm-miss", "ffffffff-ffff-ffff-ffff-ffffffffffff");
    try testing.expectEqual(@as(usize, 0), removed);

    var loaded = try store.load("sess-rm-miss");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("only", loaded.history[0].content);
}

test "removeTurnByUuid preserves snapshot records and round-trips encrypted survivors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    // encryption_enabled = true exercises the decode/re-encrypt path so
    // the rewrite must decrypt each line, drop the match, re-encrypt the
    // survivors, and leave the snapshot record intact. The keychain may
    // be unavailable in CI, so any init failure skips rather than fails.
    var store = Store.init(testing.allocator, sessions_dir, true) catch return error.SkipZigTest;
    defer store.deinit();
    if (store.encryption_key == null) return error.SkipZigTest;

    const a = "0000aaaa-0000-0000-0000-00000000aaaa";
    const b = "0000bbbb-0000-0000-0000-00000000bbbb";
    try store.appendTurn("sess-rm-enc", .user, "keep me", a);
    try store.appendTurn("sess-rm-enc", .assistant, "drop me", b);

    const snapshot = emptySnapshot();
    try store.appendSnapshot("sess-rm-enc", &snapshot, "the summary", "");

    const removed = try store.removeTurnByUuid("sess-rm-enc", b);
    try testing.expectEqual(@as(usize, 1), removed);

    var loaded = try store.load("sess-rm-enc");
    defer loaded.deinit(testing.allocator);

    // Only the surviving turn remains, decrypted correctly...
    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("keep me", loaded.history[0].content);
    try testing.expectEqualStrings(a, loaded.history[0].uuid);
    // ...and the snapshot record survived the rewrite.
    try testing.expectEqualStrings("the summary", loaded.conversation_summary);
}

test "skills-04 appendSnapshot persists activated_conditional_skills and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    var snapshot = emptySnapshot();
    const activated = [_][]const u8{ "deploy", "lint:fix" };
    snapshot.activated_conditional_skills = &activated;
    try store.appendSnapshot("sess-activated", &snapshot, "summary", "");

    var loaded = try store.load("sess-activated");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), loaded.snapshot.activated_conditional_skills.len);
    try testing.expectEqualStrings("deploy", loaded.snapshot.activated_conditional_skills[0]);
    try testing.expectEqualStrings("lint:fix", loaded.snapshot.activated_conditional_skills[1]);
}

test "skills-04 load defaults activated_conditional_skills to empty for a legacy snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const legacy = "{\"type\":\"snapshot\",\"conversation_summary\":\"old\",\"timestamp\":7}\n";
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "legacy-act.jsonl", .data = legacy });

    var loaded = try store.load("legacy-act");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), loaded.snapshot.activated_conditional_skills.len);
}

test "appendSnapshot persists message_count_at_snapshot and load reads it back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    var snapshot = emptySnapshot();
    snapshot.message_count_at_snapshot = 7;
    try store.appendSnapshot("sess-count", &snapshot, "summary", "");

    var loaded = try store.load("sess-count");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 7), loaded.snapshot.message_count_at_snapshot);
}

test "checkResumeConsistency reports no drift when counts match" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-ck", .user, "one", "ck111111-0000-0000-0000-000000000001");
    try store.appendTurn("sess-ck", .assistant, "two", "ck222222-0000-0000-0000-000000000002");
    var snapshot = emptySnapshot();
    snapshot.message_count_at_snapshot = 2; // matches the two turns above
    try store.appendSnapshot("sess-ck", &snapshot, "summary", "");

    var loaded = try store.load("sess-ck");
    defer loaded.deinit(testing.allocator);

    const report = Store.checkResumeConsistency(&loaded);
    try testing.expect(!report.has_drift);
    try testing.expectEqual(@as(usize, 2), report.loaded_count);
    try testing.expectEqual(@as(usize, 2), report.expected_count);
}

test "checkResumeConsistency reports drift when the loaded count diverges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-drift", .user, "one", "dr111111-0000-0000-0000-000000000001");
    try store.appendTurn("sess-drift", .assistant, "two", "dr222222-0000-0000-0000-000000000002");
    var snapshot = emptySnapshot();
    // Snapshot recorded 3 turns, but only 2 are on disk -> drift.
    snapshot.message_count_at_snapshot = 3;
    try store.appendSnapshot("sess-drift", &snapshot, "summary", "");

    var loaded = try store.load("sess-drift");
    defer loaded.deinit(testing.allocator);

    const report = Store.checkResumeConsistency(&loaded);
    try testing.expect(report.has_drift);
    try testing.expectEqual(@as(usize, 2), report.loaded_count);
    try testing.expectEqual(@as(usize, 3), report.expected_count);
}

test "checkResumeConsistency skips the check when the snapshot recorded no count" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-legacy-ck", .user, "one", "lg111111-0000-0000-0000-000000000001");
    const snapshot = emptySnapshot(); // message_count_at_snapshot defaults to 0
    try store.appendSnapshot("sess-legacy-ck", &snapshot, "summary", "");

    var loaded = try store.load("sess-legacy-ck");
    defer loaded.deinit(testing.allocator);

    const report = Store.checkResumeConsistency(&loaded);
    // expected_count == 0 means "no reference recorded" -> never drift.
    try testing.expect(!report.has_drift);
    try testing.expectEqual(@as(usize, 0), report.expected_count);
}

test "cleanupOldSessions deletes files past the retention cutoff" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // Create three session files: two recent, one ancient.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "fresh-1.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "fresh-2.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ancient.jsonl", .data = "{}\n" });

    // Backdate ancient.jsonl to 60 days ago by setting its mtime
    // via futimens-equivalent. Zig's std.fs doesn't expose utimensat
    // directly, so we use the underlying File.updateTimes method.
    {
        const ancient = try tmp.dir.openFile(rt.io, "ancient.jsonl", .{ .mode = .read_write });
        defer ancient.close(rt.io);
        const sixty_days_ago_ns: i128 = clock.nowNanos() - 60 * std.time.ns_per_s * 24 * 60 * 60;
        ancient.setTimestamps(rt.io, .{ .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(sixty_days_ago_ns) } }, .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(sixty_days_ago_ns) } } }) catch {};
    }

    // Ask the store to clean up anything older than 30 days.
    const result = try store.cleanupOldSessions(30);
    try testing.expectEqual(@as(usize, 1), result.deleted);
    try testing.expectEqual(@as(usize, 0), result.errors);

    // Fresh files survive.
    try tmp.dir.access(rt.io, "fresh-1.jsonl", .{});
    try tmp.dir.access(rt.io, "fresh-2.jsonl", .{});
    // Ancient is gone.
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "ancient.jsonl", .{}));
}

test "cleanupOldSessions is a no-op when retention_days = 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "anything.jsonl", .data = "{}\n" });

    const result = try store.cleanupOldSessions(0);
    try testing.expectEqual(@as(usize, 0), result.deleted);
    try tmp.dir.access(rt.io, "anything.jsonl", .{});
}

test "setLabel / readLabel roundtrip persists to sidecar file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // No label exists yet.
    try testing.expectEqual(@as(?[]u8, null), try store.readLabel("my-session"));

    // Set and read it back.
    try store.setLabel("my-session", "Fix login button");
    const label = try store.readLabel("my-session");
    try testing.expect(label != null);
    defer testing.allocator.free(label.?);
    try testing.expectEqualStrings("Fix login button", label.?);

    // The sidecar file exists on disk.
    try tmp.dir.access(rt.io, "my-session.label", .{});
}

test "setLabel empty string deletes the sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.setLabel("foo", "something");
    try store.setLabel("foo", "");
    try testing.expectEqual(@as(?[]u8, null), try store.readLabel("foo"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "foo.label", .{}));
}

test "setColor / readColor roundtrip persists to sidecar and empty clears it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // No color exists yet (default).
    try testing.expectEqual(@as(?[]u8, null), try store.readColor("my-session"));

    // Set and read it back.
    try store.setColor("my-session", "blue");
    const color = try store.readColor("my-session");
    try testing.expect(color != null);
    defer testing.allocator.free(color.?);
    try testing.expectEqualStrings("blue", color.?);
    try tmp.dir.access(rt.io, "my-session.color", .{});

    // Empty clears the sidecar (reset to default).
    try store.setColor("my-session", "");
    try testing.expectEqual(@as(?[]u8, null), try store.readColor("my-session"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "my-session.color", .{}));
}

test "readLabel trims trailing whitespace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // Editor left a trailing newline.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "bar.label", .data = "Refactor auth middleware\n" });
    const label = try store.readLabel("bar");
    try testing.expect(label != null);
    defer testing.allocator.free(label.?);
    try testing.expectEqualStrings("Refactor auth middleware", label.?);
}

test "list populates label when sidecar present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "labelled.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "labelled.label", .data = "Debug CI flake" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "unlabelled.jsonl", .data = "{}\n" });

    const entries = try store.list();
    defer store.freeSessionEntries(entries);

    var found_labelled = false;
    var found_unlabelled = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, "labelled")) {
            found_labelled = true;
            try testing.expect(entry.label != null);
            try testing.expectEqualStrings("Debug CI flake", entry.label.?);
        } else if (std.mem.eql(u8, entry.id, "unlabelled")) {
            found_unlabelled = true;
            try testing.expectEqual(@as(?[]u8, null), entry.label);
        }
    }
    try testing.expect(found_labelled);
    try testing.expect(found_unlabelled);
}

test "setAiTitle / readAiTitle roundtrip persists to sidecar file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // No AI title exists yet.
    try testing.expectEqual(@as(?[]u8, null), try store.readAiTitle("s1"));

    try store.setAiTitle("s1", "Fix login flow");
    const ai = try store.readAiTitle("s1");
    try testing.expect(ai != null);
    defer testing.allocator.free(ai.?);
    try testing.expectEqualStrings("Fix login flow", ai.?);

    // The sidecar file exists on disk under the .aititle suffix.
    try tmp.dir.access(rt.io, "s1.aititle", .{});
}

test "setAiTitle empty string deletes the sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.setAiTitle("s2", "Something");
    try store.setAiTitle("s2", "");
    try testing.expectEqual(@as(?[]u8, null), try store.readAiTitle("s2"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "s2.aititle", .{}));
}

test "setAiTitle strips embedded newlines so the title stays single-line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.setAiTitle("s3", "first line\nsecond line");
    const ai = try store.readAiTitle("s3");
    try testing.expect(ai != null);
    defer testing.allocator.free(ai.?);
    try testing.expect(std.mem.indexOfScalar(u8, ai.?, '\n') == null);
    try testing.expectEqualStrings("first line second line", ai.?);
}

test "currentTitle precedence: label wins, then ai-title, then id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // Neither label nor ai-title: falls back to the raw id (freshly allocated).
    {
        const t = try store.currentTitle("sess-id");
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("sess-id", t);
    }

    // Only an ai-title: returns the ai-title.
    try store.setAiTitle("sess-id", "Auto Generated Title");
    {
        const t = try store.currentTitle("sess-id");
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("Auto Generated Title", t);
    }

    // A user label overrides the ai-title even when both exist.
    try store.setLabel("sess-id", "User Renamed");
    {
        const t = try store.currentTitle("sess-id");
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("User Renamed", t);
    }
}

test "setBranch / readBranch roundtrip persists to sidecar file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try testing.expectEqual(@as(?[]u8, null), try store.readBranch("s1"));

    try store.setBranch("s1", "feature/login-fix");
    const branch = try store.readBranch("s1");
    try testing.expect(branch != null);
    defer testing.allocator.free(branch.?);
    try testing.expectEqualStrings("feature/login-fix", branch.?);

    try tmp.dir.access(rt.io, "s1.branch", .{});
}

test "setBranch empty string deletes the sidecar" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.setBranch("s2", "main");
    try store.setBranch("s2", "");
    try testing.expectEqual(@as(?[]u8, null), try store.readBranch("s2"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(rt.io, "s2.branch", .{}));
}

test "setFirstPromptIfAbsent / readFirstPrompt roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try testing.expectEqual(@as(?[]u8, null), try store.readFirstPrompt("fp"));

    const wrote = try store.setFirstPromptIfAbsent("fp", "  Fix the login button  ");
    try testing.expect(wrote);
    const fp = try store.readFirstPrompt("fp");
    try testing.expect(fp != null);
    defer testing.allocator.free(fp.?);
    try testing.expectEqualStrings("Fix the login button", fp.?);

    try tmp.dir.access(rt.io, "fp.firstprompt", .{});
}

test "setFirstPromptIfAbsent writes only once (second user turn does not overwrite)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const first = try store.setFirstPromptIfAbsent("once", "original prompt");
    try testing.expect(first);

    // A later user turn must NOT clobber the recorded first prompt.
    const second = try store.setFirstPromptIfAbsent("once", "a different later prompt");
    try testing.expect(!second);

    const fp = try store.readFirstPrompt("once");
    try testing.expect(fp != null);
    defer testing.allocator.free(fp.?);
    try testing.expectEqualStrings("original prompt", fp.?);
}

test "setFirstPromptIfAbsent ignores an empty prompt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const wrote = try store.setFirstPromptIfAbsent("empty", "   \n\t  ");
    try testing.expect(!wrote);
    try testing.expectEqual(@as(?[]u8, null), try store.readFirstPrompt("empty"));
}

test "first-prompt sidecar collapses embedded newlines so the preview stays single-line" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    _ = try store.setFirstPromptIfAbsent("multi", "line one\nline two");
    const fp = try store.readFirstPrompt("multi");
    try testing.expect(fp != null);
    defer testing.allocator.free(fp.?);
    try testing.expectEqualStrings("line one line two", fp.?);
}

test "addPrLink / readPrLinks roundtrip and dedup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // Empty to start.
    {
        const links = try store.readPrLinks("pr");
        defer store.freeTags(links);
        try testing.expectEqual(@as(usize, 0), links.len);
    }

    try testing.expect(try store.addPrLink("pr", "https://github.com/o/r/pull/1"));
    try testing.expect(try store.addPrLink("pr", "https://github.com/o/r/pull/2"));
    // Duplicate is rejected.
    try testing.expect(!(try store.addPrLink("pr", "https://github.com/o/r/pull/1")));
    // Empty is rejected.
    try testing.expect(!(try store.addPrLink("pr", "   ")));

    const links = try store.readPrLinks("pr");
    defer store.freeTags(links);
    try testing.expectEqual(@as(usize, 2), links.len);
    try testing.expectEqualStrings("https://github.com/o/r/pull/1", links[0]);
    try testing.expectEqualStrings("https://github.com/o/r/pull/2", links[1]);

    try tmp.dir.access(rt.io, "pr.prlinks", .{});
}

test "cleanupOldSessions skips non-jsonl files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // A leftover swap file or backup that happens to be old must
    // not get swept up -- only the jsonl session files are eligible.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "notes.txt", .data = "x" });
    {
        const stale = try tmp.dir.openFile(rt.io, "notes.txt", .{ .mode = .read_write });
        defer stale.close(rt.io);
        const long_ago_ns: i128 = clock.nowNanos() - 365 * std.time.ns_per_s * 24 * 60 * 60;
        stale.setTimestamps(rt.io, .{ .access_timestamp = .{ .new = .{ .nanoseconds = @intCast(long_ago_ns) } }, .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(long_ago_ns) } } }) catch {};
    }

    const result = try store.cleanupOldSessions(30);
    try testing.expectEqual(@as(usize, 0), result.deleted);
    try tmp.dir.access(rt.io, "notes.txt", .{});
}
