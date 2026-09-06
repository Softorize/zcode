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
const git_fs = @import("../core/git_fs.zig");
const build_options = @import("build_options");
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
    /// Cheap best-effort origin cwd (sessions-storage-04), read from the
    /// `<id>.origin` sidecar written by appendTurn/appendSnapshot the first
    /// time a session is touched with a known `active_cwd`. null when the
    /// sidecar is missing (legacy session, or a session that has never been
    /// written to with a known cwd). Owned by the entry; freed via
    /// freeSessionEntries.
    origin_cwd: ?[]u8 = null,
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
    /// `<zcode_home>` -- the parent directory of `sessions_dir`. Computed
    /// once at init so per-project bucket paths
    /// (`<zcode_home>/projects/<slug>/`, sessions-storage-02) can be derived
    /// without re-deriving it on every call. Owned; freed in deinit.
    zcode_home: []u8,
    /// The live working directory this Store instance is operating on
    /// (sessions-storage-02/04). Borrowed: every current production entry
    /// point (session_mgmt.runInteractive/runOneShot/resumeSessionInteractive,
    /// the cwd-aware session_cmds commands) sets this directly --
    /// `store.active_cwd = cwd;` -- right after construction, from a `cwd`
    /// string that already outlives the Store, so Store never copies or
    /// frees it. The default "" means "no project context known": every
    /// path resolution falls back to the pre-migration flat
    /// `<zcode_home>/sessions/` layout, so any caller that never opts in
    /// (background replay, bundle fork/checkpoint helpers, test harnesses)
    /// is byte-for-byte unaffected by the sessions-storage-02 migration.
    active_cwd: []const u8 = "",
    /// One-shot override consumed by the very next `createSessionId` call
    /// (sessions-storage-03: `--session-id <uuid>`). Sessions minted
    /// without a pin get a fresh UUIDv4 as usual. Owned; freed by deinit if
    /// a caller sets it but nothing ever consumes it (e.g. a rejected run).
    pinned_next_session_id: ?[]u8 = null,
    /// One-shot flag consumed by the very next `appendSnapshot` call
    /// (sessions-storage-missed-199): when set, the snapshot record is
    /// marked `isCompactSummary: true` and preceded by a
    /// `{"type":"system","subtype":"compact_boundary",...}` marker record,
    /// mirroring the reference's post-/compact transcript shape.
    mark_next_snapshot_compact: bool = false,
    /// Cap on a single session's on-disk `.jsonl` size before
    /// `trimIfOversized` drops the oldest whole records
    /// (sessions-storage-missed-200). Matches `load()`'s own 256 MiB read
    /// cap by default; a test can shrink this to exercise the trim path
    /// without writing hundreds of megabytes.
    max_session_bytes: u64 = 256 * 1024 * 1024,

    pub fn init(allocator: std.mem.Allocator, sessions_dir: []const u8, encryption_enabled: bool) !Store {
        try paths.ensureDir(sessions_dir);
        const key = try loadSessionKey(allocator, encryption_enabled);
        const home = std.fs.path.dirname(sessions_dir) orelse sessions_dir;
        return .{
            .allocator = allocator,
            .sessions_dir = try allocator.dupe(u8, sessions_dir),
            .encryption_enabled = encryption_enabled,
            .encryption_key = key,
            .zcode_home = try allocator.dupe(u8, home),
        };
    }

    /// Pin the id the next `createSessionId` call returns (sessions-storage-03
    /// `--session-id <uuid>`). Consumed exactly once; a second call to
    /// `createSessionId` before another `pinNextSessionId` mints a fresh
    /// UUIDv4 as usual.
    pub fn pinNextSessionId(self: *Store, id: []const u8) !void {
        if (self.pinned_next_session_id) |old| self.allocator.free(old);
        self.pinned_next_session_id = try self.allocator.dupe(u8, id);
    }

    /// Mark the next `appendSnapshot` call as a post-compaction summary
    /// (sessions-storage-missed-199). See `mark_next_snapshot_compact`.
    pub fn markNextSnapshotAsCompact(self: *Store) void {
        self.mark_next_snapshot_compact = true;
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
        self.allocator.free(self.zcode_home);
        if (self.pinned_next_session_id) |p| self.allocator.free(p);
    }

    /// Mint a session id. sessions-storage-03: Claude Code session ids are
    /// RFC4122 UUIDv4 strings (and `--session-id <uuid>` lets a caller pin an
    /// exact one via `pinNextSessionId`), so we mint the same shape
    /// `core/uuid.v4Hex` already produces for per-turn ids, rather than the
    /// previous `<epoch>-<32-hex-nonce>` format.
    pub fn createSessionId(self: *Store) ![]u8 {
        if (self.pinned_next_session_id) |pinned| {
            self.pinned_next_session_id = null;
            return pinned; // ownership transferred to the caller
        }
        var buf: [36]u8 = undefined;
        uuid.v4Hex(&buf);
        return self.allocator.dupe(u8, &buf);
    }

    /// Append a turn record to the session JSONL. `turn_uuid` is the
    /// stable per-turn id; pass "" to have the store mint a fresh
    /// canonical UUID-v4 (the common replay path -- e.g. resuming a
    /// bundle). When the in-memory `History` already minted a uuid for
    /// the live turn it passes that same id so the on-disk record and the
    /// in-memory turn share it.
    ///
    /// sessions-storage-01: the on-disk shape is Claude Code's own
    /// transcript record -- `type` (user/assistant/system), `uuid`,
    /// `parentUuid` (chains turns into a linked list; null for the first
    /// turn a session ever writes), `sessionId`, an ISO-8601 `timestamp`,
    /// `cwd`/`version`/`gitBranch`, `message: {role, content}`,
    /// `isSidechain`, `userType`, `requestId`, and (for a tool-result turn)
    /// `toolUseResult` -- rather than the previous zcode-only
    /// `{type:"turn",role,content,timestamp,uuid}` shape. `load()` still
    /// reads the legacy shape transparently (additive migration: existing
    /// session files are never rewritten).
    pub fn appendTurn(self: *Store, session_id: []const u8, role: types.HistoryRole, content: []const u8, turn_uuid: []const u8) !void {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |dir| try paths.ensureDir(dir);

        // sessions-storage-04: cheap, write-once origin breadcrumb so a
        // picker/resume command can learn where this session started
        // without a full Store.load. Best-effort -- a failure here must
        // never block the turn append itself.
        if (self.active_cwd.len > 0) {
            _ = self.setOriginIfAbsent(session_id, self.active_cwd) catch {};
        }

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

        const parent_uuid = self.lastRecordUuid(path);
        defer if (parent_uuid) |p| self.allocator.free(p);

        const timestamp = try formatIso8601(self.allocator, clock.nowSeconds());
        defer self.allocator.free(timestamp);

        const branch: ?[]u8 = if (self.active_cwd.len > 0) git_fs.currentBranch(self.allocator, self.active_cwd) else null;
        defer if (branch) |b| self.allocator.free(b);

        const cc_type = ccRecordTypeForRole(role);

        var record_buf = std_io.StringBuilder.init(self.allocator);
        defer record_buf.deinit();

        if (role == .tool) {
            // Tool-result turns are `user`-typed at the top level (there is
            // no separate "tool" type in Claude's own transcript schema)
            // and carry a sibling `toolUseResult` field -- that's how a
            // reader distinguishes a plain user turn from a tool result.
            // `message.role` keeps the more precise "tool" tag (rather than
            // "user") so `load()`'s `parseRole` round-trips `.tool` exactly
            // -- compaction/export/session_memory all branch on it.
            try record_buf.writer().print("{f}", .{std.json.fmt(.{
                .type = cc_type,
                .uuid = effective_uuid,
                .parentUuid = parent_uuid,
                .sessionId = session_id,
                .timestamp = timestamp,
                .cwd = self.active_cwd,
                .version = build_options.app_version,
                .gitBranch = branch orelse "",
                .message = .{ .role = "tool", .content = content },
                .isSidechain = false,
                .userType = "external",
                .requestId = @as(?[]const u8, null),
                .toolUseResult = content,
            }, .{})});
        } else {
            try record_buf.writer().print("{f}", .{std.json.fmt(.{
                .type = cc_type,
                .uuid = effective_uuid,
                .parentUuid = parent_uuid,
                .sessionId = session_id,
                .timestamp = timestamp,
                .cwd = self.active_cwd,
                .version = build_options.app_version,
                .gitBranch = branch orelse "",
                .message = .{ .role = cc_type, .content = content },
                .isSidechain = false,
                .userType = "external",
                .requestId = @as(?[]const u8, null),
            }, .{})});
        }

        try self.appendRecordLine(file, record_buf.items());
        self.trimIfOversized(path);
    }

    /// Append a snapshot record. `origin_cwd` is an optional breadcrumb
    /// (sessions-04) recording the working directory the session was
    /// active in; pass "" for replay-created sessions where origin has
    /// no meaning (bundle restore, CLI re-snapshot). The live REPL path
    /// passes the runtime's cwd so a picker can later display origin.
    ///
    /// sessions-storage-01/missed-201: the record now also carries the
    /// Claude-Code envelope fields (`uuid`, `parentUuid`, `sessionId`,
    /// ISO-8601 `timestamp`, `cwd`, `version`, `gitBranch`) around zcode's
    /// own extension fields (facts/decisions/etc, kept as-is -- CC's own
    /// `summary` record type is exactly meant to be extended like this).
    /// sessions-storage-missed-199: when `markNextSnapshotAsCompact` was
    /// called, this snapshot is preceded by a `compact_boundary` system
    /// record and marked `isCompactSummary: true`.
    pub fn appendSnapshot(self: *Store, session_id: []const u8, snapshot: *const types.SessionSnapshot, conversation_summary: []const u8, origin_cwd: []const u8) !void {
        const path = try self.sessionPath(session_id);
        defer self.allocator.free(path);
        if (std.fs.path.dirname(path)) |dir| try paths.ensureDir(dir);

        if (origin_cwd.len > 0) {
            _ = self.setOriginIfAbsent(session_id, origin_cwd) catch {};
        }

        const file = try openAppendFile(path);
        defer file.close(rt.io);
        file.setPermissions(rt.io, std.Io.File.Permissions.fromMode(0o600)) catch |err| {
            std.log.warn("session: failed to chmod {s}: {s}", .{ path, @errorName(err) });
        };

        const timestamp = try formatIso8601(self.allocator, clock.nowSeconds());
        defer self.allocator.free(timestamp);

        const effective_cwd = if (origin_cwd.len > 0) origin_cwd else self.active_cwd;
        const branch: ?[]u8 = if (effective_cwd.len > 0) git_fs.currentBranch(self.allocator, effective_cwd) else null;
        defer if (branch) |b| self.allocator.free(b);

        const is_compact = self.mark_next_snapshot_compact;
        self.mark_next_snapshot_compact = false;
        if (is_compact) {
            try self.appendCompactBoundaryRecord(file, session_id, timestamp);
        }

        var minted: [36]u8 = undefined;
        uuid.v4Hex(&minted);
        const parent_uuid = self.lastRecordUuid(path);
        defer if (parent_uuid) |p| self.allocator.free(p);

        // sessions-storage-missed-201: re-stamp the sidecar-backed metadata
        // fields onto EVERY summary record (this runs after every turn --
        // see agent_runtime.zig's call site) so the sidecar-absent jsonl
        // fallback in readLabel/readAiTitle/readTags/readMode/readColor/
        // readPrLinks always has a value as-of the last turn, even when the
        // sidecars themselves never make it along with the `.jsonl` (copied
        // to another machine, or simply deleted). customTitle/aiTitle/tag
        // mirror the reference's own field names; zcodeMode/zcodeColor/
        // prLinks are zcode extensions (coordinator mode, the prompt-bar
        // accent color, and a flat PR-link list have no reference
        // equivalent) -- consistent with every other zcode-only field
        // already on this record (facts/decisions/etc).
        const custom_title = try self.readLabel(session_id);
        defer if (custom_title) |v| self.allocator.free(v);
        const ai_title = try self.readAiTitle(session_id);
        defer if (ai_title) |v| self.allocator.free(v);
        const zcode_mode = try self.readMode(session_id);
        defer if (zcode_mode) |v| self.allocator.free(v);
        const zcode_color = try self.readColor(session_id);
        defer if (zcode_color) |v| self.allocator.free(v);

        const tags = try self.readTags(session_id);
        defer self.freeTags(tags);
        const tag_joined = try std.mem.join(self.allocator, ",", tags);
        defer self.allocator.free(tag_joined);

        const pr_links = try self.readPrLinks(session_id);
        defer self.freeTags(pr_links);
        const pr_joined = try std.mem.join(self.allocator, ",", pr_links);
        defer self.allocator.free(pr_joined);

        var record_buf = std_io.StringBuilder.init(self.allocator);
        defer record_buf.deinit();

        try record_buf.writer().print("{f}", .{std.json.fmt(.{
            .type = "summary",
            .uuid = &minted,
            .parentUuid = parent_uuid,
            .sessionId = session_id,
            .timestamp = timestamp,
            .cwd = effective_cwd,
            .version = build_options.app_version,
            .gitBranch = branch orelse "",
            .isSidechain = false,
            .userType = "external",
            .isCompactSummary = is_compact,
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
            .customTitle = custom_title,
            .aiTitle = ai_title,
            .tag = tag_joined,
            .zcodeMode = zcode_mode,
            .zcodeColor = zcode_color,
            .prLinks = pr_joined,
        }, .{})});

        try self.appendRecordLine(file, record_buf.items());
        self.trimIfOversized(path);
    }

    /// Emit a `{"type":"system","subtype":"compact_boundary",...}` marker
    /// record (sessions-storage-missed-199) immediately before the
    /// post-compaction summary record, mirroring the reference's
    /// `$l(e) => e?.type==="system" && e.subtype==="compact_boundary"`
    /// transcript marker so downstream consumers can skip/collapse the
    /// summarized region.
    fn appendCompactBoundaryRecord(self: *Store, file: std.Io.File, session_id: []const u8, timestamp: []const u8) !void {
        var minted: [36]u8 = undefined;
        uuid.v4Hex(&minted);

        var record_buf = std_io.StringBuilder.init(self.allocator);
        defer record_buf.deinit();
        try record_buf.writer().print("{f}", .{std.json.fmt(.{
            .type = "system",
            .subtype = "compact_boundary",
            .uuid = &minted,
            .sessionId = session_id,
            .timestamp = timestamp,
            .isSidechain = false,
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
            } else if (std.mem.eql(u8, kind, "user") or std.mem.eql(u8, kind, "assistant") or std.mem.eql(u8, kind, "system")) {
                // sessions-storage-01: Claude-Code-shaped turn record. A
                // bare `type:"system"` (no `subtype`) is a role turn; a
                // `subtype:"compact_boundary"` system record
                // (sessions-storage-missed-199) is a structural marker with
                // no `message` payload, so it falls through untouched.
                if (getString(obj, "subtype") != null) continue;
                const message_obj = switch (obj.get("message") orelse continue) {
                    .object => |m| m,
                    else => continue,
                };
                const role_str = getString(message_obj, "role") orelse kind;
                const content = getString(message_obj, "content") orelse continue;
                const ts_iso = getString(obj, "timestamp");
                const ts = if (ts_iso) |s| (parseIso8601ToEpoch(s) orelse clock.nowSeconds()) else clock.nowSeconds();
                const turn_uuid = getString(obj, "uuid") orelse "";

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
            } else if (std.mem.eql(u8, kind, "snapshot") or std.mem.eql(u8, kind, "summary")) {
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

    /// List every session in `self.sessions_dir` (the pre-migration flat
    /// layout). This is the ORIGINAL `list()` behavior, preserved exactly
    /// so every caller that never opts into a `cwd` (background replay, the
    /// REPL session switcher, tests) keeps seeing what it always did.
    /// sessions-storage-02's per-project view lives in `listForActiveProject`
    /// / `listAllProjects` below.
    pub fn list(self: *Store) ![]SessionEntry {
        return self.listDir(self.sessions_dir);
    }

    /// List sessions in the CURRENT project's bucket (sessions-storage-02/04:
    /// `<zcode_home>/projects/<slug(active_cwd)>/`) when `active_cwd` is
    /// known; otherwise falls back to `list()`'s flat-directory scan so a
    /// caller that never set `active_cwd` is unaffected.
    pub fn listForActiveProject(self: *Store) ![]SessionEntry {
        if (self.active_cwd.len == 0) return self.list();
        const project_dir = try self.projectDirForCwd(self.active_cwd);
        defer self.allocator.free(project_dir);
        return self.listDir(project_dir);
    }

    /// List every session across the legacy flat directory AND every
    /// `<zcode_home>/projects/<slug>/` bucket (sessions-storage-02
    /// `--all-projects` / `-a`). Each entry's `origin_cwd` (when present)
    /// tells the caller which project it came from.
    pub fn listAllProjects(self: *Store) ![]SessionEntry {
        var out = std.array_list.Managed(SessionEntry).init(self.allocator);
        errdefer {
            for (out.items) |e| {
                self.allocator.free(e.id);
                if (e.label) |l| self.allocator.free(l);
                if (e.origin_cwd) |o| self.allocator.free(o);
            }
            out.deinit();
        }

        // Legacy flat dir. list() dupes id/label/origin -- take ownership by
        // moving each entry into `out` and freeing only the outer slice.
        const legacy = try self.list();
        defer self.allocator.free(legacy);
        try out.appendSlice(legacy);

        const projects_root = try std.fs.path.join(self.allocator, &.{ self.zcode_home, "projects" });
        defer self.allocator.free(projects_root);
        var dir = std.Io.Dir.cwd().openDir(rt.io, projects_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                std.mem.sort(SessionEntry, out.items, {}, lessRecentFirst);
                return out.toOwnedSlice();
            },
            else => return err,
        };
        defer dir.close(rt.io);

        var it = dir.iterate();
        while (try it.next(rt.io)) |entry| {
            if (entry.kind != .directory) continue;
            const sub_dir = try std.fs.path.join(self.allocator, &.{ projects_root, entry.name });
            defer self.allocator.free(sub_dir);
            const sub_entries = self.listDir(sub_dir) catch continue;
            defer self.allocator.free(sub_entries);
            try out.appendSlice(sub_entries);
        }

        std.mem.sort(SessionEntry, out.items, {}, lessRecentFirst);
        return out.toOwnedSlice();
    }

    /// Shared readdir scan behind `list`/`listForActiveProject`/
    /// `listAllProjects`. Reads the `.label`/`.origin` sidecars directly out
    /// of `dir_path` (rather than through the general `sessionPath`
    /// resolver) since the caller already knows exactly where the `.jsonl`
    /// lives -- this keeps a directory listing to two stats per entry
    /// instead of triggering the resolver's cross-project scan fallback.
    fn listDir(self: *Store, dir_path: []const u8) ![]SessionEntry {
        var dir = std.Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return self.allocator.alloc(SessionEntry, 0),
            else => return err,
        };
        defer dir.close(rt.io);

        var it = dir.iterate();
        var out = std.array_list.Managed(SessionEntry).init(self.allocator);
        defer out.deinit();

        while (try it.next(rt.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

            const id = entry.name[0 .. entry.name.len - ".jsonl".len];
            const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(file_path);

            const stat = try std.Io.Dir.cwd().statFile(rt.io, file_path, .{});
            const ts: i64 = @intCast(@divTrunc(stat.mtime.toNanoseconds(), std.time.ns_per_s));

            // Reserve the out slot first so the final append is
            // infallible; otherwise id_owned and label_slice (if non-null)
            // leaked when out.append OOM'd.
            try out.ensureUnusedCapacity(1);
            const id_owned = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_owned);
            // Best-effort sidecar reads: missing is the common case (never
            // renamed / no known origin), so swallow errors.
            const label_slice = self.readSidecarInDir(dir_path, id, ".label", 1024) catch null;
            const origin_slice = self.readSidecarInDir(dir_path, id, ".origin", 4096) catch null;
            // Tags are an opt-in per-session sidecar read; most
            // sessions have none. list() stays cheap by leaving
            // entry.tags empty -- callers that actually need tags
            // call readTags(id) themselves.
            out.appendAssumeCapacity(.{
                .id = id_owned,
                .updated_ts = ts,
                .label = label_slice,
                .origin_cwd = origin_slice,
            });
        }

        std.mem.sort(SessionEntry, out.items, {}, lessRecentFirst);
        return out.toOwnedSlice();
    }

    fn readSidecarInDir(self: *Store, dir_path: []const u8, id: []const u8, suffix: []const u8, limit: usize) !?[]u8 {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ id, suffix });
        defer self.allocator.free(filename);
        const path = try std.fs.path.join(self.allocator, &.{ dir_path, filename });
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, limit);
    }

    pub fn freeSessionEntries(self: *Store, entries: []SessionEntry) void {
        for (entries) |entry| {
            self.allocator.free(entry.id);
            if (entry.label) |label| self.allocator.free(label);
            if (entry.origin_cwd) |origin| self.allocator.free(origin);
            if (entry.tags.len > 0) self.freeTags(entry.tags);
        }
        self.allocator.free(entries);
    }

    /// Shared sidecar-path builder for every `<id>.<suffix>` metadata file
    /// (`.label`, `.tags`, `.aititle`, `.branch`, `.mode`, `.color`,
    /// `.firstprompt`, `.prlinks`, `.origin`, `.parent`). Resolves through
    /// `sessionPath` (rather than hardcoding `self.sessions_dir`) so a
    /// sidecar always lives next to wherever this session's `.jsonl`
    /// actually is (or will be) -- essential once sessions-storage-02
    /// per-project buckets exist, since a session's real directory is no
    /// longer always the flat `sessions_dir`.
    fn sidecarPath(self: *Store, session_id: []const u8, suffix: []const u8) ![]u8 {
        const session_file = try self.sessionPath(session_id);
        defer self.allocator.free(session_file);
        const base = session_file[0 .. session_file.len - ".jsonl".len];
        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, suffix });
    }

    fn tagsPath(self: *Store, session_id: []const u8) ![]u8 {
        return self.sidecarPath(session_id, ".tags");
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

    /// Read the tag list for `session_id`. Prefers the `.tags` sidecar; when
    /// it is missing (sessions-storage-missed-201 -- a session predating the
    /// sidecar, or a `.jsonl` copied elsewhere without it) falls back to the
    /// comma-joined `tag` field `appendSnapshot` stamps onto every summary
    /// record with the tags current as of that turn, mirroring the
    /// reference's own `tag` field. Returns an empty slice when neither
    /// source has any tags. Caller owns the result (free via `freeTags`).
    pub fn readTags(self: *Store, session_id: []const u8) ![][]u8 {
        const path = try self.tagsPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self.tagsFromJsonlFallback(session_id),
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

    /// sessions-storage-missed-201: split the last record's comma-joined
    /// `tag` field back into individual tags. Returns an empty slice (never
    /// an error) when the session file is missing or has no `tag` field.
    fn tagsFromJsonlFallback(self: *Store, session_id: []const u8) ![][]u8 {
        const session_path = self.sessionPath(session_id) catch return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(session_path);
        const joined = self.lastRecordField(session_path, "tag") orelse return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(joined);

        var out = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (out.items) |item| self.allocator.free(item);
            out.deinit();
        }
        var it = std.mem.splitScalar(u8, joined, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
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
        return self.sidecarPath(session_id, ".label");
    }

    /// Read the human-readable label for `session_id`. Prefers the
    /// `.label` sidecar file `<sessions_dir>/<session_id>.label`; when it is
    /// missing (sessions-storage-missed-201 -- a session predating the
    /// sidecar, or a `.jsonl` copied elsewhere without it) falls back to the
    /// `customTitle` field `appendSnapshot` stamps onto every summary
    /// record, mirroring the reference's own `customTitle` field. Returns
    /// null when neither source has one (the common case -- sessions start
    /// without a label). Caller owns the returned slice.
    pub fn readLabel(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.labelPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => {
                const session_path = self.sessionPath(session_id) catch return null;
                defer self.allocator.free(session_path);
                return self.lastRecordField(session_path, "customTitle");
            },
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
        return self.sidecarPath(session_id, ".aititle");
    }

    /// Read the AI-generated title for `session_id`. Prefers the
    /// `.aititle` sidecar file `<sessions_dir>/<session_id>.aititle`; when
    /// it is missing (sessions-storage-missed-201 -- predates the sidecar,
    /// or a `.jsonl` copied elsewhere without it) falls back to the
    /// `aiTitle` field `appendSnapshot` stamps onto every summary record,
    /// mirroring the reference's own `aiTitle` field. Returns null when
    /// neither source has one (common case -- a title is generated
    /// best-effort after the first turn and may never exist offline).
    /// Caller owns the returned slice.
    pub fn readAiTitle(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.aiTitlePath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => {
                const session_path = self.sessionPath(session_id) catch return null;
                defer self.allocator.free(session_path);
                return self.lastRecordField(session_path, "aiTitle");
            },
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
        return self.sidecarPath(session_id, ".branch");
    }

    /// Read the persisted git branch for `session_id`. Prefers the `.branch`
    /// sidecar (cheap, and reflects the branch as of the LAST write to it);
    /// when the sidecar is missing (session predates the sidecar, or the
    /// `.jsonl` was copied to another machine without it -- sessions-
    /// storage-missed-201) falls back to the `gitBranch` field zcode's own
    /// Claude-Code-shaped schema (sessions-storage-01) already stamps on
    /// every turn record, so the branch is never silently lost even when
    /// only the `.jsonl` survives. Returns null when neither source has it.
    /// Caller owns the returned slice.
    pub fn readBranch(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.branchPath(session_id);
        defer self.allocator.free(path);
        if (try readTrimmedSidecar(self.allocator, path, 1024)) |sidecar| return sidecar;

        const session_path = self.sessionPath(session_id) catch return null;
        defer self.allocator.free(session_path);
        return self.lastRecordField(session_path, "gitBranch");
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
        return self.sidecarPath(session_id, ".mode");
    }

    /// Read the persisted session mode for `session_id` (e.g. "coordinator" or
    /// "normal"). Prefers the `.mode` sidecar; when it is missing
    /// (sessions-storage-missed-201 -- pre-feature, a session that never
    /// recorded a mode, or a `.jsonl` copied elsewhere without its sidecar)
    /// falls back to the `zcodeMode` field `appendSnapshot` stamps onto
    /// every summary record (a zcode extension -- coordinator mode has no
    /// reference equivalent). Returns null when neither source has one.
    /// Caller owns the returned slice. Used by the resume path to
    /// reconcile coordinator mode (remote-server-01).
    pub fn readMode(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.modePath(session_id);
        defer self.allocator.free(path);
        if (try readTrimmedSidecar(self.allocator, path, 256)) |sidecar| return sidecar;

        const session_path = self.sessionPath(session_id) catch return null;
        defer self.allocator.free(session_path);
        return self.lastRecordField(session_path, "zcodeMode");
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
        return self.sidecarPath(session_id, ".color");
    }

    /// Read the persisted prompt-bar accent color for `session_id`
    /// (commands-sweep-03). Prefers the `.color` sidecar; when it is
    /// missing (sessions-storage-missed-201 -- a `.jsonl` copied elsewhere
    /// without its sidecar) falls back to the `zcodeColor` field
    /// `appendSnapshot` stamps onto every summary record (a zcode
    /// extension -- the accent color has no reference equivalent). Returns
    /// null when neither source has one (default color). Caller owns the
    /// returned slice.
    pub fn readColor(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.colorPath(session_id);
        defer self.allocator.free(path);
        if (try readTrimmedSidecar(self.allocator, path, 64)) |sidecar| return sidecar;

        const session_path = self.sessionPath(session_id) catch return null;
        defer self.allocator.free(session_path);
        return self.lastRecordField(session_path, "zcodeColor");
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
        return self.sidecarPath(session_id, ".firstprompt");
    }

    /// Read the persisted first user prompt for `session_id`. Prefers the
    /// `.firstprompt` sidecar (a cheap, pre-truncated cache); when it is
    /// missing (session predates the sidecar, or the `.jsonl` was copied
    /// elsewhere without it -- sessions-storage-missed-201) falls back to
    /// scanning the `.jsonl` itself for its first user turn's content,
    /// mirroring the reference's own `extractFirstPromptFromEntries` (the
    /// first prompt IS just the first user message; no separate write is
    /// needed for a reader that has the transcript). Returns null when
    /// neither source has one. Caller owns the returned slice.
    pub fn readFirstPrompt(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.firstPromptPath(session_id);
        defer self.allocator.free(path);
        if (try readTrimmedSidecar(self.allocator, path, 16 * 1024)) |sidecar| return sidecar;

        const session_path = self.sessionPath(session_id) catch return null;
        defer self.allocator.free(session_path);
        return self.firstUserTurnContent(session_path);
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
        return self.sidecarPath(session_id, ".prlinks");
    }

    /// Return the path to the origin-cwd sidecar (`<id>.origin`,
    /// sessions-storage-04). Caller owns the returned slice.
    fn originPath(self: *Store, session_id: []const u8) ![]u8 {
        return self.sidecarPath(session_id, ".origin");
    }

    /// Read the cheap origin-cwd breadcrumb for `session_id` without a full
    /// `Store.load` (sessions-storage-04). Returns null when the sidecar is
    /// missing (a legacy session, or one that was never written to with a
    /// known `active_cwd`). Caller owns the returned slice.
    pub fn readOrigin(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.originPath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 4096);
    }

    /// Persist `cwd` as `session_id`'s origin breadcrumb ONLY if no
    /// `.origin` sidecar exists yet (write-once, mirroring
    /// `setFirstPromptIfAbsent`). Returns true when it wrote, false when one
    /// was already present or `cwd` is blank. Called from
    /// appendTurn/appendSnapshot whenever `active_cwd`/`origin_cwd` is known.
    pub fn setOriginIfAbsent(self: *Store, session_id: []const u8, cwd: []const u8) !bool {
        const trimmed = std.mem.trim(u8, cwd, " \t\r\n");
        if (trimmed.len == 0) return false;

        const path = try self.originPath(session_id);
        defer self.allocator.free(path);

        if (readTrimmedSidecar(self.allocator, path, 4096)) |existing| {
            if (existing) |e| {
                self.allocator.free(e);
                return false;
            }
        } else |_| {}

        try paths.ensureDir(std.fs.path.dirname(path) orelse self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, trimmed);
        return true;
    }

    /// Return the path to the parent-session-id sidecar (`<id>.parent`,
    /// sessions-storage-08): the id of the session `/clear` regenerated
    /// THIS one from, for traceability. Caller owns the returned slice.
    fn parentSessionIdPath(self: *Store, session_id: []const u8) ![]u8 {
        return self.sidecarPath(session_id, ".parent");
    }

    /// Read the parent-session-id breadcrumb for `session_id`
    /// (sessions-storage-08). Returns null when absent (every session that
    /// wasn't minted by `/clear`). Caller owns the returned slice.
    pub fn readParentSessionId(self: *Store, session_id: []const u8) !?[]u8 {
        const path = try self.parentSessionIdPath(session_id);
        defer self.allocator.free(path);
        return readTrimmedSidecar(self.allocator, path, 512);
    }

    /// Record that `session_id` was regenerated from `parent_id` by
    /// `/clear` (sessions-storage-08).
    pub fn setParentSessionId(self: *Store, session_id: []const u8, parent_id: []const u8) !void {
        const path = try self.parentSessionIdPath(session_id);
        defer self.allocator.free(path);
        try paths.ensureDir(std.fs.path.dirname(path) orelse self.sessions_dir);
        try writeSidecarAtomic(self.allocator, path, parent_id);
    }

    /// Regenerate the session id for `/clear`/`/reset`/`/new`
    /// (sessions-storage-08): mirrors edualc's
    /// `regenerateSessionId({ setCurrentAsParent: true })` +
    /// `resetSessionFilePointer()` (src/commands/clear/conversation.ts:203-208).
    /// Writes `old_session_id` a final snapshot (best-effort -- a failure here
    /// must never block the caller from actually clearing, since the whole
    /// point is to leave a clean, resumable stopping point, not to guarantee
    /// one), mints a brand-new UUIDv4 id via `createSessionId` (honoring any
    /// pending `pinNextSessionId`), and records `old_session_id` as the new
    /// id's `.parent` sidecar for traceability. The OLD session's `.jsonl` is
    /// left completely untouched apart from that final snapshot line; the
    /// returned id has no turns on disk yet. Caller owns the result and is
    /// responsible for pointing the live runtime at it (free the old id,
    /// assign the new one) -- this function only touches the store.
    pub fn regenerateSessionForClear(
        self: *Store,
        old_session_id: []const u8,
        final_snapshot: *const types.SessionSnapshot,
        conversation_summary: []const u8,
    ) ![]u8 {
        self.appendSnapshot(old_session_id, final_snapshot, conversation_summary, self.active_cwd) catch |err| {
            std.log.warn("session: /clear final snapshot on {s} failed: {s}", .{ old_session_id, @errorName(err) });
        };
        const new_id = try self.createSessionId();
        errdefer self.allocator.free(new_id);
        self.setParentSessionId(new_id, old_session_id) catch |err| {
            std.log.warn("session: /clear could not record parent sidecar for {s}: {s}", .{ new_id, @errorName(err) });
        };
        return new_id;
    }

    /// Best-effort size-based transcript trim (sessions-storage-missed-200):
    /// the reference tracks and can shrink an oversized transcript rather
    /// than growing it unbounded (bundle symbols `oversized`, `keptBytes`,
    /// `straddleSnapCarryLen`, `boundaryStartOffset` sit right next to its
    /// isCompactSummary logic). Once `path` exceeds `self.max_session_bytes`
    /// this drops the OLDEST whole records until the file is back under half
    /// the cap, and writes a `{"type":"system","subtype":"transcript_trimmed",
    /// "droppedBytes":N,"droppedRecords":M}` marker record in their place so
    /// a reader knows earlier history was cut from disk -- the in-memory
    /// conversation and any compaction summary already taken are unaffected;
    /// this only bounds the on-disk file. Records are kept/dropped as OPAQUE
    /// raw lines (never decoded), so trimming behaves identically whether or
    /// not session encryption is enabled. Called after every append; never
    /// propagates an error -- a failed trim just leaves the file oversized
    /// until the next successful append, exactly like the pre-this-gap
    /// behavior.
    fn trimIfOversized(self: *Store, path: []const u8) void {
        const stat = std.Io.Dir.cwd().statFile(rt.io, path, .{}) catch return;
        if (stat.size <= self.max_session_bytes) return;

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(self.max_session_bytes * 4 + 1024)) catch return;
        defer self.allocator.free(bytes);

        var lines = std.array_list.Managed([]const u8).init(self.allocator);
        defer lines.deinit();
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            lines.append(line) catch return;
        }
        if (lines.items.len <= 1) return; // nothing safe to drop

        const target: usize = @intCast(self.max_session_bytes / 2);

        // Walk from the tail, keeping whole lines until the next one would
        // push us past target -- but always keep at least the last line so
        // a very large single record can never leave the file empty.
        var kept_bytes: usize = 0;
        var keep_from: usize = lines.items.len;
        while (keep_from > 0) {
            const candidate_len = lines.items[keep_from - 1].len + 1; // + '\n'
            if (kept_bytes > 0 and kept_bytes + candidate_len > target) break;
            kept_bytes += candidate_len;
            keep_from -= 1;
        }
        if (keep_from == 0) return; // whole file already fits from the tail

        var dropped_bytes: usize = 0;
        for (lines.items[0..keep_from]) |line| dropped_bytes += line.len + 1;

        const timestamp = formatIso8601(self.allocator, clock.nowSeconds()) catch return;
        defer self.allocator.free(timestamp);
        var minted: [36]u8 = undefined;
        uuid.v4Hex(&minted);

        var out = std_io.StringBuilder.init(self.allocator);
        defer out.deinit();
        out.writer().print("{f}\n", .{std.json.fmt(.{
            .type = "system",
            .subtype = "transcript_trimmed",
            .uuid = &minted,
            .timestamp = timestamp,
            .isSidechain = false,
            .droppedBytes = dropped_bytes,
            .droppedRecords = keep_from,
        }, .{})}) catch return;
        for (lines.items[keep_from..]) |line| {
            out.writer().print("{s}\n", .{line}) catch return;
        }

        writeJsonlAtomic(self.allocator, path, out.items()) catch {};
    }

    /// Read the PR links for `session_id` (one per line). Prefers the
    /// `.prlinks` sidecar; when it is missing (sessions-storage-missed-201
    /// -- a `.jsonl` copied elsewhere without its sidecar) falls back to
    /// the comma-joined `prLinks` field `appendSnapshot` stamps onto every
    /// summary record (a zcode extension bundling what the reference keeps
    /// as separate `prNumber`/`prRepository` fields). Returns a
    /// heap-allocated slice (possibly empty when neither source has any).
    /// Callers ALWAYS pair the return with `freeTags` to keep ownership
    /// uniform (same shape/free rule as readTags).
    pub fn readPrLinks(self: *Store, session_id: []const u8) ![][]u8 {
        const path = try self.prLinksPath(session_id);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self.prLinksFromJsonlFallback(session_id),
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

    /// sessions-storage-missed-201: split the last record's comma-joined
    /// `prLinks` field back into individual links. Returns an empty slice
    /// (never an error) when the session file is missing or has no
    /// `prLinks` field.
    fn prLinksFromJsonlFallback(self: *Store, session_id: []const u8) ![][]u8 {
        const session_path = self.sessionPath(session_id) catch return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(session_path);
        const joined = self.lastRecordField(session_path, "prLinks") orelse return try self.allocator.alloc([]u8, 0);
        defer self.allocator.free(joined);

        var out = std.array_list.Managed([]u8).init(self.allocator);
        errdefer {
            for (out.items) |item| self.allocator.free(item);
            out.deinit();
        }
        var it = std.mem.splitScalar(u8, joined, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
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

    /// Read the `uuid` of the LAST record already on disk at `path`
    /// (sessions-storage-01 `parentUuid` chaining). Best-effort thin
    /// wrapper over `lastRecordField`.
    fn lastRecordUuid(self: *Store, path: []const u8) ?[]u8 {
        return self.lastRecordField(path, "uuid");
    }

    /// Read a top-level string `field` off the LAST record already on disk
    /// at `path` (sessions-storage-01 `parentUuid` chaining;
    /// sessions-storage-missed-201's `readBranch`/`readFirstPrompt`
    /// sidecar-free fallback -- mirrors the reference's own
    /// `extractFieldFromLastEntryStrict` JSONL-native metadata extraction
    /// rather than a side file). Reads only the tail of the file (64 KiB,
    /// mirroring `core/logger.reseedPrevHashFromFile`'s tail-read idiom) so
    /// this stays cheap even on a very large session. Returns null when the
    /// file doesn't exist, is empty, the last line is corrupt/unparseable/
    /// larger than the tail window, or lacks that field -- every caller
    /// treats a miss as "no such record", not an error. Best-effort by
    /// design: no error is ever propagated to the caller.
    fn lastRecordField(self: *Store, path: []const u8, field: []const u8) ?[]u8 {
        const file = std.Io.Dir.cwd().openFile(rt.io, path, .{}) catch return null;
        defer file.close(rt.io);

        const end_pos = file.length(rt.io) catch return null;
        if (end_pos == 0) return null;

        const tail_cap: u64 = 64 * 1024;
        const tail_len: u64 = @min(end_pos, tail_cap);
        const tail_start = end_pos - tail_len;

        const buf = self.allocator.alloc(u8, @intCast(tail_len)) catch return null;
        defer self.allocator.free(buf);
        const read_len = file.readPositionalAll(rt.io, buf, tail_start) catch return null;
        if (read_len == 0) return null;
        const tail = buf[0..read_len];

        // The file always ends with '\n' (every append writes one), so walk
        // back past trailing newlines, then back to the start of that line.
        var end: usize = tail.len;
        while (end > 0 and tail[end - 1] == '\n') : (end -= 1) {}
        if (end == 0) return null;
        var start: usize = end;
        while (start > 0 and tail[start - 1] != '\n') : (start -= 1) {}
        const last_line = tail[start..end];
        if (last_line.len == 0) return null;
        // A last "line" spanning the entire tail window with no newline
        // before it, when the file is bigger than the window, means a
        // single record wider than 64 KiB precedes it -- we can't safely
        // tell where it starts. Skip rather than guess.
        if (start == 0 and tail_start > 0) return null;

        const decoded = self.decodeRecordLine(last_line) catch return null;
        defer self.allocator.free(decoded);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, decoded, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const found = getString(parsed.value.object, field) orelse return null;
        if (found.len == 0) return null;
        return self.allocator.dupe(u8, found) catch null;
    }

    /// Scan `path` from the START for the first "user"-typed turn record's
    /// `message.content` (sessions-storage-missed-201: mirrors the
    /// reference's `extractFirstPromptFromEntries` -- the very first user
    /// message already IS the session's "first prompt", no separate write
    /// needed). Reads at most `first_prompt_scan_cap` bytes so a very large
    /// session cannot make this scan expensive; returns null on any error,
    /// a missing file, or no user turn found in that scanned prefix.
    /// Best-effort: never propagates an error.
    fn firstUserTurnContent(self: *Store, path: []const u8) ?[]u8 {
        const first_prompt_scan_cap: usize = 256 * 1024;
        const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, self.allocator, .limited(first_prompt_scan_cap)) catch return null;
        defer self.allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const decoded = self.decodeRecordLine(line) catch continue;
            defer self.allocator.free(decoded);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, decoded, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const obj = parsed.value.object;
            const kind = getString(obj, "type") orelse continue;
            if (!(std.mem.eql(u8, kind, "user") or std.mem.eql(u8, kind, "turn"))) continue;
            if (getString(obj, "subtype") != null) continue; // a structural marker, not a turn
            // Legacy `{"type":"turn","role":"user",...}` shape.
            if (std.mem.eql(u8, kind, "turn")) {
                const role = getString(obj, "role") orelse continue;
                if (!std.mem.eql(u8, role, "user")) continue;
                const content = getString(obj, "content") orelse continue;
                if (content.len == 0) continue;
                return self.allocator.dupe(u8, content) catch null;
            }
            // sessions-storage-01-shaped `{"type":"user","message":{"role":...}}`.
            const message_obj = switch (obj.get("message") orelse continue) {
                .object => |m| m,
                else => continue,
            };
            const role = getString(message_obj, "role") orelse continue;
            if (!std.mem.eql(u8, role, "user")) continue;
            const content = getString(message_obj, "content") orelse continue;
            if (content.len == 0) continue;
            return self.allocator.dupe(u8, content) catch null;
        }
        return null;
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

            // sessions-storage-01: a fresh session writes `"type":"user"` /
            // `"type":"assistant"` turn records instead of the legacy
            // `"type":"turn","role":"..."` shape. Recognize both so /stats
            // and /insights don't undercount sessions written post-migration.
            // (Encrypted lines match neither substring and are silently
            // undercounted here, same pre-existing limitation as before --
            // this heuristic never decrypts.)
            const legacy_turn = std.mem.indexOf(u8, trimmed, "\"type\":\"turn\"") != null;
            const new_user = std.mem.indexOf(u8, trimmed, "\"type\":\"user\"") != null;
            const new_assistant = std.mem.indexOf(u8, trimmed, "\"type\":\"assistant\"") != null;
            if (!legacy_turn and !new_user and !new_assistant) continue;

            counts.total += 1;
            if (new_user) {
                counts.user += 1;
            } else if (new_assistant) {
                counts.assistant += 1;
            } else if (std.mem.indexOf(u8, trimmed, "\"role\":\"user\"") != null) {
                counts.user += 1;
            } else if (std.mem.indexOf(u8, trimmed, "\"role\":\"assistant\"") != null) {
                counts.assistant += 1;
            }
        }
        return counts;
    }

    /// Resolve `session_id` to its `.jsonl` path, transparently handling
    /// both the pre-migration flat layout AND the sessions-storage-02
    /// per-project layout: (1) `<zcode_home>/projects/<slug(active_cwd)>/`
    /// when a session already lives there, (2) the legacy flat
    /// `sessions_dir`, (3) a scan across every OTHER project bucket
    /// (sessions-storage-04 cross-directory resume: the session may have
    /// been started from a different cwd than the one we're running from
    /// now). When none of those find it, this is a brand-new session: it
    /// lands in the project bucket when `active_cwd` is known, else the
    /// legacy flat dir -- so every caller that never sets `active_cwd`
    /// keeps writing exactly where it always did.
    pub fn sessionPath(self: *Store, session_id: []const u8) ![]u8 {
        try validateSessionId(session_id);

        const filename = try std.fmt.allocPrint(self.allocator, "{s}.jsonl", .{session_id});
        defer self.allocator.free(filename);

        var project_candidate: ?[]u8 = null;
        errdefer if (project_candidate) |p| self.allocator.free(p);
        if (self.active_cwd.len > 0) {
            const project_dir = try self.projectDirForCwd(self.active_cwd);
            defer self.allocator.free(project_dir);
            const candidate = try std.fs.path.join(self.allocator, &.{ project_dir, filename });
            if (fileExists(candidate)) return candidate;
            project_candidate = candidate;
        }

        const legacy = try std.fs.path.join(self.allocator, &.{ self.sessions_dir, filename });
        errdefer self.allocator.free(legacy);
        if (fileExists(legacy)) {
            if (project_candidate) |p| self.allocator.free(p);
            return legacy;
        }

        if (self.findInAnyProject(filename)) |found| {
            self.allocator.free(legacy);
            if (project_candidate) |p| self.allocator.free(p);
            return found;
        }

        if (project_candidate) |p| {
            self.allocator.free(legacy);
            return p;
        }
        return legacy;
    }

    /// `<zcode_home>/projects/<slug(cwd)>` (sessions-storage-02), resolving
    /// `cwd` to its git worktree's shared main-repo root first
    /// (sessions-storage-missed-202) so every worktree of one repo lands in
    /// the same bucket. Does not create the directory -- callers that are
    /// about to write into it call `paths.ensureDir` on the result (or its
    /// dirname) themselves.
    fn projectDirForCwd(self: *Store, cwd: []const u8) ![]u8 {
        const resolved = self.resolveWorktreeRoot(cwd);
        defer if (resolved) |r| self.allocator.free(r);
        const effective = resolved orelse cwd;

        const slug = try paths.projectSlug(self.allocator, effective);
        defer self.allocator.free(slug);
        return std.fs.path.join(self.allocator, &.{ self.zcode_home, "projects", slug });
    }

    /// sessions-storage-missed-202: resolve `cwd` to its git worktree's
    /// shared main-repo root via `.git`'s `commondir` pointer, so a worktree
    /// checkout and its main checkout share one project bucket instead of
    /// being sharded by literal path. Returns null for a non-repo cwd, a
    /// main checkout (no `commondir` redirect), or any resolution failure --
    /// callers fall back to the literal `cwd`, which is exactly the
    /// pre-this-gap behavior. Caller owns a non-null result.
    fn resolveWorktreeRoot(self: *Store, cwd: []const u8) ?[]u8 {
        const git_dir = git_fs.resolveGitDir(self.allocator, cwd) orelse return null;
        defer self.allocator.free(git_dir);
        const common_dir = git_fs.getCommonDir(self.allocator, git_dir) orelse return null;
        defer self.allocator.free(common_dir);
        // commondir points at the shared `.git`; its parent is the shared
        // repo's working-tree root.
        const root = std.fs.path.dirname(common_dir) orelse return null;
        return self.allocator.dupe(u8, root) catch null;
    }

    /// Scan every `<zcode_home>/projects/<slug>/` bucket for `filename`
    /// (sessions-storage-04 cross-directory resume: the id may belong to a
    /// DIFFERENT project than the one `active_cwd` resolves to). Best-effort:
    /// any error reading `projects/` itself, or a given bucket, is treated
    /// as "not found there" rather than propagated. Caller owns a non-null
    /// result.
    fn findInAnyProject(self: *Store, filename: []const u8) ?[]u8 {
        const projects_root = std.fs.path.join(self.allocator, &.{ self.zcode_home, "projects" }) catch return null;
        defer self.allocator.free(projects_root);

        var dir = std.Io.Dir.cwd().openDir(rt.io, projects_root, .{ .iterate = true }) catch return null;
        defer dir.close(rt.io);

        var it = dir.iterate();
        while (it.next(rt.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const candidate = std.fs.path.join(self.allocator, &.{ projects_root, entry.name, filename }) catch continue;
            if (fileExists(candidate)) return candidate;
            self.allocator.free(candidate);
        }
        return null;
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
        // sessions-storage-01: a `"user"`/`"assistant"`/`"system"` record is
        // a turn UNLESS it carries `subtype` (the `compact_boundary` marker,
        // sessions-storage-missed-199, which is never a removal candidate).
        const is_turn = std.mem.eql(u8, kind, "turn") or
            ((std.mem.eql(u8, kind, "user") or std.mem.eql(u8, kind, "assistant") or std.mem.eql(u8, kind, "system")) and
                getString(obj, "subtype") == null);
        if (!is_turn) return false;
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

/// True when `path` exists and is accessible. Used by the session-path
/// resolver (sessions-storage-02/04) to probe candidate locations without
/// opening/reading them.
fn fileExists(path: []const u8) bool {
    return if (std.Io.Dir.cwd().access(rt.io, path, .{})) |_| true else |_| false;
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

/// sessions-storage-01: top-level `type` for a turn record in the
/// Claude-Code-shaped schema. There is no dedicated "tool" record type in
/// the reference -- a tool result is a `user`-typed message carrying a
/// sibling `toolUseResult` field (appendTurn attaches it separately).
fn ccRecordTypeForRole(role: types.HistoryRole) []const u8 {
    return switch (role) {
        .user, .tool => "user",
        .assistant => "assistant",
        .system => "system",
    };
}

/// Format `epoch_seconds` as `YYYY-MM-DDTHH:MM:SS.000Z` (sessions-storage-01:
/// the reference timestamps every transcript record this way, not as a raw
/// epoch integer). Negative input clamps to the epoch. Caller owns the
/// result. Paired with `parseIso8601ToEpoch` below for the read path --
/// together they round-trip exactly this fixed shape; neither is a general
/// ISO-8601 parser/formatter.
fn formatIso8601(allocator: std.mem.Allocator, epoch_seconds: i64) ![]u8 {
    const secs: u64 = if (epoch_seconds < 0) 0 else @intCast(epoch_seconds);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Inverse of `formatIso8601`: parse exactly the
/// `YYYY-MM-DDTHH:MM:SS(.sss)?Z` shape our own writer produces back into
/// epoch seconds, so a reloaded turn/snapshot keeps its true original
/// timestamp instead of showing "now". Returns null for any other shape
/// (hand-edited file, a future format change, pre-1970 date) so the caller
/// can fall back to a sane default rather than fail the whole load.
fn parseIso8601ToEpoch(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;

    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u4, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1) return null;
    if (year < std.time.epoch.epoch_year) return null; // pre-1970 not needed here

    var days: i64 = 0;
    var y: std.time.epoch.Year = std.time.epoch.epoch_year;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);

    var m: u4 = 1;
    while (m < month) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    }
    days += @as(i64, day) - 1;

    return days * @as(i64, std.time.epoch.secs_per_day) +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
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

    // Two ids created back-to-back should differ.
    try testing.expect(!std.mem.eql(u8, a, b));

    // sessions-storage-03: ids are canonical UUIDv4 (8-4-4-4-12), matching
    // Claude Code's own session-id shape, not the legacy
    // "<epoch>-<32-hex-nonce>" format.
    try testing.expectEqual(@as(usize, 36), a.len);
    try testing.expectEqual(@as(u8, '-'), a[8]);
    try testing.expectEqual(@as(u8, '-'), a[13]);
    try testing.expectEqual(@as(u8, '-'), a[18]);
    try testing.expectEqual(@as(u8, '-'), a[23]);
    try testing.expectEqual(@as(u8, '4'), a[14]); // version nibble
    for (a, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try testing.expect(std.ascii.isHex(c));
    }
}

test "pinNextSessionId overrides exactly the next createSessionId call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);
    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.pinNextSessionId("11111111-1111-4111-8111-111111111111");
    const pinned = try store.createSessionId();
    defer testing.allocator.free(pinned);
    try testing.expectEqualStrings("11111111-1111-4111-8111-111111111111", pinned);

    // Only the ONE call after pinning is overridden; the next mint is a
    // fresh UUID again.
    const fresh = try store.createSessionId();
    defer testing.allocator.free(fresh);
    try testing.expect(!std.mem.eql(u8, fresh, pinned));
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

// ── sessions-storage-01: Claude-Code-shaped JSONL schema ───────────────────

test "appendTurn writes the Claude-Code-shaped record with all required keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    store.active_cwd = root;
    // Force plaintext regardless of a pre-existing keychain entry on the
    // host running this test -- this test asserts the exact on-disk JSON
    // shape, which encryption would otherwise wrap.
    store.encryption_key = null;

    try store.appendTurn("sess-cc-schema", .user, "hello", "");
    try store.appendTurn("sess-cc-schema", .assistant, "hi there", "");
    try store.appendTurn("sess-cc-schema", .tool, "tool output here", "");

    const path = try store.sessionPath("sess-cc-schema");
    defer testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '\n');
    var seen: usize = 0;
    // `parsed` (and every string slice it hands back, including "uuid") is
    // freed by `parsed.deinit()` at the end of THIS iteration's block --
    // `prev_uuid` must be copied into a buffer that outlives that free, not
    // kept as a slice into the freed arena (that was a use-after-free: the
    // next iteration read poisoned/reused memory instead of the real uuid).
    var prev_uuid_buf: [36]u8 = undefined;
    var prev_uuid: []const u8 = "";
    while (lines.next()) |line| {
        seen += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;

        inline for (.{ "type", "uuid", "sessionId", "timestamp", "cwd", "version", "gitBranch", "message", "isSidechain", "userType" }) |key| {
            try testing.expect(obj.contains(key));
        }
        try testing.expect(obj.get("message").? == .object);
        try testing.expect(obj.get("message").?.object.contains("role"));
        try testing.expect(obj.get("message").?.object.contains("content"));
        try testing.expectEqualStrings("sess-cc-schema", obj.get("sessionId").?.string);
        try testing.expectEqualStrings(root, obj.get("cwd").?.string);

        // parentUuid chains: first turn's is JSON null, every later turn's
        // equals the previous turn's uuid.
        if (seen == 1) {
            try testing.expect(obj.get("parentUuid").? == .null);
        } else {
            try testing.expectEqualStrings(prev_uuid, obj.get("parentUuid").?.string);
        }
        const this_uuid = obj.get("uuid").?.string;
        std.mem.copyForwards(u8, prev_uuid_buf[0..this_uuid.len], this_uuid);
        prev_uuid = prev_uuid_buf[0..this_uuid.len];

        if (seen == 3) {
            // The tool-result turn carries toolUseResult.
            try testing.expect(obj.contains("toolUseResult"));
            try testing.expectEqualStrings("tool output here", obj.get("toolUseResult").?.string);
        }
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "load transparently reads a legacy pre-migration session file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // Hand-write an OLD-shape file: exactly what appendTurn/appendSnapshot
    // produced before sessions-storage-01 -- no migration/rewrite happens,
    // load() must still parse it.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "sess-legacy-shape.jsonl",
        .data =
        \\{"type":"turn","role":"user","content":"old shape hi","timestamp":1000,"uuid":"aaaaaaaa-0000-0000-0000-000000000001"}
        \\{"type":"turn","role":"assistant","content":"old shape hello","timestamp":1001,"uuid":"aaaaaaaa-0000-0000-0000-000000000002"}
        \\
        ,
    });

    var loaded = try store.load("sess-legacy-shape");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), loaded.history.len);
    try testing.expect(loaded.history[0].role == .user);
    try testing.expectEqualStrings("old shape hi", loaded.history[0].content);
    try testing.expect(loaded.history[1].role == .assistant);
    try testing.expectEqualStrings("old shape hello", loaded.history[1].content);
}

test "appendTurn + load round-trips through the new schema with timestamp fidelity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-cc-roundtrip", .user, "roundtrip me", "");
    var loaded = try store.load("sess-cc-roundtrip");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("roundtrip me", loaded.history[0].content);
    try testing.expect(loaded.history[0].role == .user);
    // clock.nowSeconds() is stubbed to a fixed value under the test runtime,
    // so the reloaded ISO-8601 timestamp must decode to exactly that value,
    // not to whatever "now" is when the assertion runs.
    try testing.expectEqual(clock.nowSeconds(), loaded.history[0].timestamp);
}

test "appendTurn preserves the tool role across a reload (not flattened to user)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-tool-role", .tool, "the tool result", "");
    var loaded = try store.load("sess-tool-role");
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expect(loaded.history[0].role == .tool);
}

test "countTurns counts new-schema user/assistant records" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    // countTurns scans raw on-disk bytes without decrypting; force
    // plaintext regardless of a pre-existing keychain entry on the host.
    store.encryption_key = null;

    try store.appendTurn("sess-count-new", .user, "one", "");
    try store.appendTurn("sess-count-new", .assistant, "two", "");
    try store.appendTurn("sess-count-new", .user, "three", "");

    const counts = try store.countTurns("sess-count-new");
    try testing.expectEqual(@as(usize, 3), counts.total);
    try testing.expectEqual(@as(usize, 2), counts.user);
    try testing.expectEqual(@as(usize, 1), counts.assistant);
}

test "removeTurnByUuid drops a matching new-schema turn record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-rm-new", .user, "keep", "rm11111-0000-0000-0000-000000000001");
    try store.appendTurn("sess-rm-new", .assistant, "drop", "rm22222-0000-0000-0000-000000000002");

    const removed = try store.removeTurnByUuid("sess-rm-new", "rm22222-0000-0000-0000-000000000002");
    try testing.expectEqual(@as(usize, 1), removed);

    var loaded = try store.load("sess-rm-new");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), loaded.history.len);
    try testing.expectEqualStrings("keep", loaded.history[0].content);
}

test "appendSnapshot marked compact writes a compact_boundary record and isCompactSummary=true" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    // This test asserts the raw on-disk JSON shape of the boundary/summary
    // records; force plaintext regardless of a pre-existing keychain entry
    // on the host running this test.
    store.encryption_key = null;

    try store.appendTurn("sess-compact", .user, "before compaction", "");
    store.markNextSnapshotAsCompact();
    const snapshot = emptySnapshot();
    try store.appendSnapshot("sess-compact", &snapshot, "summarized", "");

    const path = try store.sessionPath("sess-compact");
    defer testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '\n');
    var records = std.array_list.Managed([]const u8).init(testing.allocator);
    defer records.deinit();
    while (lines.next()) |l| try records.append(l);
    try testing.expectEqual(@as(usize, 3), records.items.len); // turn, boundary, summary

    var boundary = try std.json.parseFromSlice(std.json.Value, testing.allocator, records.items[1], .{});
    defer boundary.deinit();
    try testing.expectEqualStrings("system", boundary.value.object.get("type").?.string);
    try testing.expectEqualStrings("compact_boundary", boundary.value.object.get("subtype").?.string);

    var summary = try std.json.parseFromSlice(std.json.Value, testing.allocator, records.items[2], .{});
    defer summary.deinit();
    try testing.expectEqualStrings("summary", summary.value.object.get("type").?.string);
    try testing.expect(summary.value.object.get("isCompactSummary").?.bool);

    // The flag is one-shot: a later, un-marked appendSnapshot doesn't repeat it.
    try store.appendSnapshot("sess-compact", &snapshot, "second summary", "");
    const loaded_bytes_2 = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(loaded_bytes_2);
    try testing.expect(std.mem.count(u8, loaded_bytes_2, "compact_boundary") == 1);
}

// ── sessions-storage-02: per-project session directory sharding ───────────

test "appendTurn with active_cwd set lands under zcode_home/projects/<slug>" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    store.active_cwd = root;

    try store.appendTurn("sess-sharded", .user, "hi", "");

    const slug = try paths.projectSlug(testing.allocator, root);
    defer testing.allocator.free(slug);
    const expected_dir = try std.fs.path.join(testing.allocator, &.{ root, "projects", slug });
    defer testing.allocator.free(expected_dir);
    const expected_path = try std.fs.path.join(testing.allocator, &.{ expected_dir, "sess-sharded.jsonl" });
    defer testing.allocator.free(expected_path);

    try std.Io.Dir.cwd().access(rt.io, expected_path, .{});

    // Legacy flat sessions_dir must NOT have received this session.
    const legacy_path = try std.fs.path.join(testing.allocator, &.{ sessions_dir, "sess-sharded.jsonl" });
    defer testing.allocator.free(legacy_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, legacy_path, .{}));

    // sessionPath resolves to the same sharded location.
    const resolved = try store.sessionPath("sess-sharded");
    defer testing.allocator.free(resolved);
    try testing.expectEqualStrings(expected_path, resolved);
}

test "two different cwds shard into two distinct project directories" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);

    const cwd_a = try std.fs.path.join(testing.allocator, &.{ root, "proj-a" });
    defer testing.allocator.free(cwd_a);
    const cwd_b = try std.fs.path.join(testing.allocator, &.{ root, "proj-b" });
    defer testing.allocator.free(cwd_b);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    store.active_cwd = cwd_a;
    try store.appendTurn("sess-a", .user, "from a", "");

    store.active_cwd = cwd_b;
    try store.appendTurn("sess-b", .user, "from b", "");

    // Listing from cwd A's perspective shows only sess-a; switching the
    // active cwd to B shows only sess-b (sessions-storage-04 default filter).
    store.active_cwd = cwd_a;
    {
        const entries = try store.listForActiveProject();
        defer store.freeSessionEntries(entries);
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqualStrings("sess-a", entries[0].id);
    }
    store.active_cwd = cwd_b;
    {
        const entries = try store.listForActiveProject();
        defer store.freeSessionEntries(entries);
        try testing.expectEqual(@as(usize, 1), entries.len);
        try testing.expectEqualStrings("sess-b", entries[0].id);
    }

    // --all-projects sees both.
    {
        const entries = try store.listAllProjects();
        defer store.freeSessionEntries(entries);
        try testing.expectEqual(@as(usize, 2), entries.len);
    }
}

test "sessionPath finds a session that lives in a DIFFERENT project's bucket (cross-project resume)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);

    const cwd_a = try std.fs.path.join(testing.allocator, &.{ root, "proj-a" });
    defer testing.allocator.free(cwd_a);
    const cwd_b = try std.fs.path.join(testing.allocator, &.{ root, "proj-b" });
    defer testing.allocator.free(cwd_b);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    store.active_cwd = cwd_a;
    try store.appendTurn("sess-cross", .user, "started in a", "");

    // Now "resume" from B: active_cwd is B, but the session lives in A's
    // bucket. sessionPath must still find it via the cross-project scan.
    store.active_cwd = cwd_b;
    const resolved = try store.sessionPath("sess-cross");
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.indexOf(u8, resolved, "sess-cross.jsonl") != null);

    var loaded = try store.load("sess-cross");
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), loaded.history.len);
}

test "no active_cwd keeps writing to the pre-migration flat sessions_dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    // active_cwd left at its default "" -- every current non-cwd-aware
    // caller (background replay, bundle helpers, most tests) behaves
    // exactly as it did before this migration.

    try store.appendTurn("sess-flat", .user, "hi", "");
    const path = try std.fs.path.join(testing.allocator, &.{ sessions_dir, "sess-flat.jsonl" });
    defer testing.allocator.free(path);
    try std.Io.Dir.cwd().access(rt.io, path, .{});
}

// ── sessions-storage-04: origin breadcrumb + parent-session sidecar ───────

test "appendTurn records a cheap origin breadcrumb readable via readOrigin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "proj-a" });
    defer testing.allocator.free(cwd);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    store.active_cwd = cwd;

    try store.appendTurn("sess-origin-cheap", .user, "hi", "");

    const origin = (try store.readOrigin("sess-origin-cheap")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(origin);
    try testing.expectEqualStrings(cwd, origin);

    // listForActiveProject() surfaces the same breadcrumb without a full
    // Store.load (this session lives under active_cwd's project bucket,
    // not the flat sessions_dir plain list() scans).
    const entries = try store.listForActiveProject();
    defer store.freeSessionEntries(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(cwd, entries[0].origin_cwd.?);
}

test "setParentSessionId / readParentSessionId roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try testing.expect((try store.readParentSessionId("sess-new")) == null);
    try store.setParentSessionId("sess-new", "sess-old");
    const parent = (try store.readParentSessionId("sess-new")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(parent);
    try testing.expectEqualStrings("sess-old", parent);
}

test "regenerateSessionForClear mints a fresh id, snapshots the old session, and links parentage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-preclear", .user, "before /clear", "");

    const snapshot = emptySnapshot();
    const new_id = try store.regenerateSessionForClear("sess-preclear", &snapshot, "cleared via /clear");
    defer testing.allocator.free(new_id);

    // A brand-new UUIDv4, distinct from the old id.
    try testing.expect(!std.mem.eql(u8, new_id, "sess-preclear"));
    try testing.expectEqual(@as(usize, 36), new_id.len);

    // The old session gained a final snapshot but its pre-clear turn is
    // untouched, and the new session has no turns of its own yet.
    var old_loaded = try store.load("sess-preclear");
    defer old_loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), old_loaded.history.len);
    try testing.expectEqualStrings("before /clear", old_loaded.history[0].content);
    try testing.expectEqualStrings("cleared via /clear", old_loaded.conversation_summary);

    // The new session has no turns of its own yet -- exactly like a
    // brand-new session, its .jsonl does not exist until the first turn is
    // appended (the very next user prompt after /clear).
    const new_path = try store.sessionPath(new_id);
    defer testing.allocator.free(new_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(rt.io, new_path, .{}));

    // Parentage sidecar links the new session back to the pre-clear one.
    const parent = (try store.readParentSessionId(new_id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(parent);
    try testing.expectEqualStrings("sess-preclear", parent);
}

// ── sessions-storage-missed-200: size-based transcript trimming ───────────

test "trimIfOversized drops the oldest turns and leaves a transcript_trimmed marker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();
    // Force plaintext: this test asserts the raw on-disk shape.
    store.encryption_key = null;
    // A tiny cap so a handful of turns already trips the trim path without
    // writing hundreds of megabytes. Each Claude-Code-shaped turn envelope
    // (uuid/parentUuid/sessionId/timestamp/version/message/... ) runs a few
    // hundred bytes on its own, so the cap must comfortably exceed one
    // line + the trim marker or trimming could never get back under it.
    store.max_session_bytes = 3000;

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [64]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "turn number {d} with some padding text", .{i}) catch unreachable;
        try store.appendTurn("sess-oversized", .user, content, "");
    }

    const path = try store.sessionPath("sess-oversized");
    defer testing.allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(rt.io, path, .{});
    // Trimmed back down to at most the cap (the marker record can push it
    // slightly over half the cap, but never anywhere near the untrimmed
    // ~20-turn size).
    try testing.expect(stat.size <= store.max_session_bytes);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "transcript_trimmed") != null);
    // The earliest turns are gone; the most recent turn survives.
    try testing.expect(std.mem.indexOf(u8, bytes, "turn number 0 with") == null);
    try testing.expect(std.mem.indexOf(u8, bytes, "turn number 19 with") != null);

    // load() still parses the trimmed file (the marker record has no
    // `message` field and is skipped, not mistaken for a turn).
    var loaded = try store.load("sess-oversized");
    defer loaded.deinit(testing.allocator);
    try testing.expect(loaded.history.len > 0);
    try testing.expect(loaded.history.len < 20);
}

test "trimIfOversized is a no-op below the cap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-small", .user, "just one small turn", "");

    const path = try store.sessionPath("sess-small");
    defer testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt.io, path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "transcript_trimmed") == null);
}

// ── sessions-storage-missed-201: JSONL-native metadata fallback ───────────

test "readBranch falls back to the last record's gitBranch field when the sidecar is absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(testing.allocator, &.{ root, "sessions" });
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // No .branch sidecar was ever written -- only the .jsonl's own turn
    // records carry gitBranch (sessions-01), and only when there's a real
    // git repo at active_cwd. Set active_cwd to this test's own repo
    // checkout so git_fs.currentBranch resolves something non-empty.
    store.active_cwd = "."; // the zcode repo checkout the test runs from
    try store.appendTurn("sess-branch-fallback", .user, "hi", "");

    const branch = try store.readBranch("sess-branch-fallback");
    if (branch) |b| {
        defer testing.allocator.free(b);
        try testing.expect(b.len > 0);
    } else {
        // A CI checkout in detached-HEAD state reports no branch name --
        // acceptable as long as no error was raised.
    }

    // Explicit no-fallback case: a session with a blank gitBranch (no
    // active_cwd, so no git detection ran) has nothing to fall back to.
    var store2 = try Store.init(testing.allocator, sessions_dir, false);
    defer store2.deinit();
    try store2.appendTurn("sess-no-branch", .user, "hi", "");
    try testing.expect((try store2.readBranch("sess-no-branch")) == null);
}

test "readBranch prefers the .branch sidecar over the jsonl fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-sidecar-branch", .user, "hi", "");
    try store.setBranch("sess-sidecar-branch", "feature/explicit");

    const branch = (try store.readBranch("sess-sidecar-branch")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(branch);
    try testing.expectEqualStrings("feature/explicit", branch);
}

test "readFirstPrompt falls back to the jsonl's first user turn when the sidecar is absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    // No .firstprompt sidecar written -- mirrors a .jsonl copied to another
    // machine without its sidecars.
    try store.appendTurn("sess-fp-fallback", .user, "what is the first prompt here", "");
    try store.appendTurn("sess-fp-fallback", .assistant, "an answer", "");
    try store.appendTurn("sess-fp-fallback", .user, "a second question", "");

    const fp = (try store.readFirstPrompt("sess-fp-fallback")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(fp);
    try testing.expectEqualStrings("what is the first prompt here", fp);
}

test "readFirstPrompt prefers the .firstprompt sidecar over the jsonl fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    try store.appendTurn("sess-fp-sidecar", .user, "the real first prompt", "");
    _ = try store.setFirstPromptIfAbsent("sess-fp-sidecar", "a cached, edited preview");

    const fp = (try store.readFirstPrompt("sess-fp-sidecar")) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(fp);
    try testing.expectEqualStrings("a cached, edited preview", fp);
}

/// Mirrors the private `sidecarPath` builder so a test can delete a sidecar
/// directly (simulating a `.jsonl` copied elsewhere without it) without
/// needing store-internal access.
fn sidecarPathForTest(allocator: std.mem.Allocator, store: *Store, session_id: []const u8, suffix: []const u8) ![]u8 {
    const session_file = try store.sessionPath(session_id);
    defer allocator.free(session_file);
    const base = session_file[0 .. session_file.len - ".jsonl".len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

fn deleteSidecarForTest(allocator: std.mem.Allocator, store: *Store, session_id: []const u8, suffix: []const u8) !void {
    const path = try sidecarPathForTest(allocator, store, session_id, suffix);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(rt.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

test "sessions-storage-missed-201: readLabel/readAiTitle/readTags/readMode/readColor/readPrLinks fall back to the jsonl summary record when their sidecars are absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const id = "sess-meta-fallback";
    try store.appendTurn(id, .user, "hi", "");

    // Set every sidecar, then write a summary record -- appendSnapshot
    // re-stamps the CURRENT sidecar values onto the record it writes
    // (sessions-storage-missed-201), so this is exactly what a real
    // session accumulates as it runs.
    try store.setLabel(id, "My Custom Title");
    try store.setAiTitle(id, "An AI-Generated Title");
    try store.setTags(id, &.{ "alpha", "beta" });
    try store.setMode(id, "coordinator");
    try store.setColor(id, "blue");
    _ = try store.addPrLink(id, "https://github.com/acme/widget/pull/7");

    const snapshot = emptySnapshot();
    try store.appendSnapshot(id, &snapshot, "summary", "");

    // Now simulate the `.jsonl` being copied elsewhere WITHOUT its
    // sidecars: delete every one of them.
    try deleteSidecarForTest(testing.allocator, &store, id, ".label");
    try deleteSidecarForTest(testing.allocator, &store, id, ".aititle");
    try deleteSidecarForTest(testing.allocator, &store, id, ".tags");
    try deleteSidecarForTest(testing.allocator, &store, id, ".mode");
    try deleteSidecarForTest(testing.allocator, &store, id, ".color");
    try deleteSidecarForTest(testing.allocator, &store, id, ".prlinks");

    const label = (try store.readLabel(id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("My Custom Title", label);

    const ai_title = (try store.readAiTitle(id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(ai_title);
    try testing.expectEqualStrings("An AI-Generated Title", ai_title);

    const tags = try store.readTags(id);
    defer store.freeTags(tags);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("alpha", tags[0]);
    try testing.expectEqualStrings("beta", tags[1]);

    const mode = (try store.readMode(id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(mode);
    try testing.expectEqualStrings("coordinator", mode);

    const color = (try store.readColor(id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(color);
    try testing.expectEqualStrings("blue", color);

    const pr_links = try store.readPrLinks(id);
    defer store.freeTags(pr_links);
    try testing.expectEqual(@as(usize, 1), pr_links.len);
    try testing.expectEqualStrings("https://github.com/acme/widget/pull/7", pr_links[0]);
}

test "sessions-storage-missed-201: readLabel/readTags prefer their sidecar over the jsonl fallback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const sessions_dir = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(sessions_dir);

    var store = try Store.init(testing.allocator, sessions_dir, false);
    defer store.deinit();

    const id = "sess-meta-sidecar-wins";
    try store.appendTurn(id, .user, "hi", "");
    try store.setLabel(id, "stamped title");
    try store.setTags(id, &.{"stamped-tag"});

    const snapshot = emptySnapshot();
    try store.appendSnapshot(id, &snapshot, "summary", "");

    // Sidecars are updated AFTER the stamp -- the sidecar (fresher) must win
    // over the jsonl's now-stale value, exactly like readBranch/
    // readFirstPrompt's existing sidecar-wins precedent.
    try store.setLabel(id, "fresher title");
    try store.setTags(id, &.{"fresher-tag"});

    const label = (try store.readLabel(id)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(label);
    try testing.expectEqualStrings("fresher title", label);

    const tags = try store.readTags(id);
    defer store.freeTags(tags);
    try testing.expectEqual(@as(usize, 1), tags.len);
    try testing.expectEqualStrings("fresher-tag", tags[0]);
}

// ── sessions-storage-03: UUIDv4 session ids, sessions-storage-missed-202 ──

test "projectDirForCwd resolves a worktree checkout to the SAME bucket as its main repo" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try @import("../core/test_helpers.zig").tmpDirCwd(allocator, &tmp);
    defer allocator.free(root);

    const main_repo = try std.fs.path.join(allocator, &.{ root, "main" });
    defer allocator.free(main_repo);
    try paths.ensureDir(main_repo);

    const runGit = struct {
        fn run(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) bool {
            const result = std.process.run(alloc, rt.io, .{
                .argv = argv,
                .cwd = .{ .path = cwd },
                .stdout_limit = .limited(64 * 1024),
                .stderr_limit = .limited(64 * 1024),
            }) catch return false;
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);
            return switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
        }
    }.run;

    if (!runGit(allocator, main_repo, &.{ "git", "init", "-q" })) return error.SkipZigTest;
    _ = runGit(allocator, main_repo, &.{ "git", "config", "user.email", "t@example.com" });
    _ = runGit(allocator, main_repo, &.{ "git", "config", "user.name", "T" });
    _ = runGit(allocator, main_repo, &.{ "git", "config", "commit.gpgsign", "false" });
    {
        const f = try std.fs.path.join(allocator, &.{ main_repo, "a.txt" });
        defer allocator.free(f);
        const file = try std.Io.Dir.cwd().createFile(rt.io, f, .{ .truncate = true });
        defer file.close(rt.io);
        try file.writeStreamingAll(rt.io, "hi\n");
    }
    if (!runGit(allocator, main_repo, &.{ "git", "add", "a.txt" })) return error.SkipZigTest;
    if (!runGit(allocator, main_repo, &.{ "git", "commit", "-q", "-m", "init" })) return error.SkipZigTest;

    const worktree_path = try std.fs.path.join(allocator, &.{ root, "wt" });
    defer allocator.free(worktree_path);
    if (!runGit(allocator, main_repo, &.{ "git", "worktree", "add", "-q", worktree_path, "-b", "wt-branch" })) {
        return error.SkipZigTest;
    }

    const sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(sessions_dir);
    var store = try Store.init(allocator, sessions_dir, false);
    defer store.deinit();

    const dir_from_main = try store.projectDirForCwd(main_repo);
    defer allocator.free(dir_from_main);
    const dir_from_worktree = try store.projectDirForCwd(worktree_path);
    defer allocator.free(dir_from_worktree);

    try testing.expectEqualStrings(dir_from_main, dir_from_worktree);
}
