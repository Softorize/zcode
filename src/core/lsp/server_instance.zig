//! One persistent language-server child process (parity lsp-02).
//!
//! Owns the spawned `std.process.Child`, keeps its stdin open (the bug in the
//! stateless `tools/lsp.zig` is closing stdin after the first write, which is
//! what makes that path unable to receive passive notifications), runs one
//! background reader thread that frames inbound messages by Content-Length, and
//! routes each message:
//!   - responses (id + result/error) -> a mutex-guarded inbox keyed by id
//!   - notifications (method, no id)  -> the notification handler (lsp-01)
//!   - server requests (id + method) -> the request handler (lsp-09)
//!
//! `sendRequest` writes a framed request to stdin and polls the inbox until the
//! reader thread delivers the matching id (or the timeout elapses). Writes to
//! stdin are serialized with a mutex because both the main thread (sendRequest)
//! and the reader thread (server-request replies) write there.
//!
//! 0.16 note: `std.Io.Condition` has no timed-wait, so the inbox uses a short
//! poll loop (like the MCP client's deadline-bounded reads) rather than a
//! condition variable with a timeout. The inbox is still mutex-guarded so the
//! reader thread and the waiter never race.
//!
//! This module is the structural analogue of the MCP client's persistent stdio
//! session read path. lsp-05 (lifecycle/crash recovery), lsp-06 (retry),
//! lsp-09 (reverse requests), and lsp-11 (rich capabilities) extend it.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../std_io.zig");
const clock = @import("../clock.zig");
const protocol = @import("protocol.zig");
const registry_mod = @import("registry.zig");
const config_mod = @import("config.zig");
const backoff = @import("../backoff.zig");

/// 30s handshake / request timeout, mirroring the MCP client's
/// MCP_STDIO_TIMEOUT_MS. lsp-05 lets a config inject a shorter timeout; lsp-02
/// uses this default.
pub const REQUEST_TIMEOUT_MS: i64 = 30 * 1000;

/// Default crash-recovery cap (lsp-05). A server that keeps crashing is stopped
/// being restarted after this many recoveries, mirroring the reference's
/// `maxRestarts ?? 3` (LSPServerInstance.ts:113-264). lsp-07's config can
/// override this per-server.
pub const DEFAULT_MAX_RESTARTS: u32 = 3;

/// Poll interval while waiting for a response. Small enough to be responsive,
/// large enough not to spin the CPU.
const POLL_SLICE_NS: u64 = 2 * std.time.ns_per_ms;

/// Maximum framed body size we will read from a server (defensive cap).
const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// lsp-11: the client `capabilities` object advertised in the `initialize`
/// request. A realistic capability set so servers behave correctly. This is a
/// static, content-free constant (no untrusted/plugin values), so a compile-time
/// JSON literal is the safe, allocation-free way to carry it; per-server config
/// (lsp-07) is spliced separately as `initializationOptions`, never inside this
/// blob.
///
/// Mirrors the reference `InitializeParams.capabilities` (LSPServerInstance.ts
/// :167-237):
///   - `general.positionEncodings:["utf-16"]` -- our 0-based line/character
///     offsets are UTF-16 code units; declaring this keeps hover/definition
///     columns correct on files with non-ASCII (a correctness, not cosmetic,
///     concern noted in the lsp-11 footguns).
///   - `workspace.configuration:false` + `workspace.workspaceFolders:true` --
///     we *handle* server-initiated `workspace/configuration` (lsp-09) but
///     declaring `false` matches the reference and minimizes config requests.
///   - `textDocument.publishDiagnostics` with `relatedInformation` +
///     `tagSupport` (valueSet 1=Unnecessary, 2=Deprecated) + `codeDescriptionSupport`.
///   - `textDocument.hover.contentFormat:["markdown","plaintext"]`.
///   - `definition`/`implementation`/`typeDefinition`/`references`/`declaration`
///     with `linkSupport:true`.
///   - `documentSymbol.hierarchicalDocumentSymbolSupport:true`.
///   - `callHierarchy.dynamicRegistration:true`.
const client_capabilities_json =
    \\{"general":{"positionEncodings":["utf-16"]},"workspace":{"configuration":false,"workspaceFolders":true},"textDocument":{"publishDiagnostics":{"relatedInformation":true,"versionSupport":true,"codeDescriptionSupport":true,"dataSupport":true,"tagSupport":{"valueSet":[1,2]}},"synchronization":{"didSave":true,"willSave":false,"willSaveWaitUntil":false,"dynamicRegistration":true},"hover":{"contentFormat":["markdown","plaintext"],"dynamicRegistration":true},"definition":{"linkSupport":true,"dynamicRegistration":true},"declaration":{"linkSupport":true,"dynamicRegistration":true},"implementation":{"linkSupport":true,"dynamicRegistration":true},"typeDefinition":{"linkSupport":true,"dynamicRegistration":true},"references":{"dynamicRegistration":true},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true,"dynamicRegistration":true},"callHierarchy":{"dynamicRegistration":true}}}
;

/// Lifecycle state machine (lsp-05). Transitions:
///   stopped -> starting -> running        (clean start)
///   running -> stopping -> stopped         (clean shutdown)
///   any     -> error_state                 (spawn/handshake/crash failure)
///   error_state -> starting                (restart, bounded by max_restarts)
/// Mirrors the reference's `state: stopped|starting|running|stopping|error`
/// (LSPServerInstance.ts:113-264).
pub const State = enum { stopped, starting, running, stopping, error_state };

/// A pending or delivered response, stored in the inbox keyed by request id.
const InboxEntry = struct {
    /// The framed-stripped response body, owned by the instance allocator.
    /// Null until the reader thread delivers it.
    body: ?[]u8 = null,
    /// Set when the stream closed / server crashed before a response arrived,
    /// so a polling `sendRequest` wakes with an error instead of timing out.
    failed: bool = false,
};

/// Signature of the optional notification handler. Receives the server name,
/// the method name, and the raw params-bearing message body (framing already
/// stripped). The body is owned by the caller for the duration of the call.
pub const NotificationFn = *const fn (ctx: ?*anyopaque, name: []const u8, method: []const u8, body: []const u8) void;

pub const ServerInstance = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// The server name (e.g. "zls"); used in notification routing and logs.
    name: []const u8,
    /// argv used to spawn (owned by this instance: each element + the slice).
    argv: [][]const u8,

    child: ?std.process.Child = null,
    state: State = .stopped,

    /// lsp-05 crash recovery: how many times the reader loop has observed an
    /// unexpected exit (EOF while `running`). `start()` refuses to restart once
    /// this exceeds `max_restarts`, so a persistently-crashing server is left in
    /// `error_state` rather than respawned forever. Mirrors `crashRecoveryCount`
    /// in LSPClient.ts:156-167 / LSPServerInstance.ts.
    crash_recovery_count: u32 = 0,
    /// lsp-05: how many times `start()` has (re)spawned the child. Distinct from
    /// crash_recovery_count, which only counts unexpected exits. The first clean
    /// start counts as 1.
    restart_count: u32 = 0,
    /// lsp-05: crash-recovery cap. Defaults to DEFAULT_MAX_RESTARTS (3); lsp-07's
    /// config can lower/raise it per server.
    max_restarts: u32 = DEFAULT_MAX_RESTARTS,
    /// lsp-05: wall-clock ms when the current start began. Lets a future health
    /// check reason about uptime; set on each `start()`.
    start_time: i64 = 0,
    /// lsp-05: the last failure that put the instance into `error_state`, for
    /// diagnostics. Null on a clean lifecycle.
    last_error: ?anyerror = null,
    /// lsp-05: handshake startup timeout. The `initialize` round-trip must
    /// complete within this many ms or `start()` fails with `error.Timeout` and
    /// the child is killed. Defaults to the 30s request timeout; tests inject a
    /// short value so the timeout path does not block the suite. lsp-07's config
    /// can set this per server.
    startup_timeout_ms: i64 = REQUEST_TIMEOUT_MS,

    /// Background reader thread; joined on stop.
    reader_thread: ?std.Thread = null,
    /// Set by stop() to ask the reader thread to exit even if the pipe is open.
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Monotonically increasing request id. id 1 is reserved for `initialize`.
    next_id: i64 = 2,

    /// Inbox of responses keyed by request id. Guarded by `inbox_mutex`.
    inbox: std.AutoHashMapUnmanaged(i64, InboxEntry) = .{},
    inbox_mutex: std.Io.Mutex = .init,

    /// Serializes all writes to the child's stdin (sendRequest + reverse-request
    /// replies from the reader thread both write here).
    write_mutex: std.Io.Mutex = .init,

    /// Optional passive-notification sink (lsp-01 wires this).
    notify_fn: ?NotificationFn = null,
    notify_ctx: ?*anyopaque = null,

    /// Optional passive-diagnostics registry (lsp-01). When set, a
    /// `textDocument/publishDiagnostics` notification on the reader thread is
    /// parsed and routed into the registry, so the next agent turn can inject
    /// the diagnostics without a tool call. Null in the stateless / test paths
    /// that only exercise the round-trip.
    registry: ?*registry_mod.Registry = null,

    /// Optional resolved server config (lsp-07). When set, the handshake splices
    /// the config's `initializationOptions` into the `initialize` params (some
    /// servers, e.g. vue-language-server, require them) and advertises the
    /// config's `workspaceFolder`. Null -> the minimal init body (lsp-02) is
    /// sent. The pointed-to config is owned by the caller and must outlive the
    /// instance's `start`. `startup_timeout_ms` / `max_restarts` are also read
    /// from the config when it is set (the caller can otherwise set the fields
    /// directly).
    config: ?*const config_mod.LspServerConfig = null,

    /// Allocate the instance and dupe argv/name into the instance allocator. The
    /// child is not spawned until `start`.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        argv: []const []const u8,
    ) !*ServerInstance {
        const self = try allocator.create(ServerInstance);
        errdefer allocator.destroy(self);

        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const owned_argv = try allocator.alloc([]const u8, argv.len);
        errdefer allocator.free(owned_argv);
        var filled: usize = 0;
        errdefer for (owned_argv[0..filled]) |a| allocator.free(a);
        for (argv, 0..) |a, i| {
            owned_argv[i] = try allocator.dupe(u8, a);
            filled = i + 1;
        }

        self.* = .{
            .allocator = allocator,
            .io = io,
            .name = owned_name,
            .argv = owned_argv,
        };
        return self;
    }

    /// Free the instance and all owned memory. Stops the server first if it is
    /// still running. Safe to call once.
    pub fn destroy(self: *ServerInstance) void {
        self.stop();
        for (self.argv) |a| self.allocator.free(a);
        self.allocator.free(self.argv);
        self.allocator.free(self.name);
        // Free any leftover inbox entries (responses that were never claimed).
        var it = self.inbox.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.body) |b| self.allocator.free(b);
        }
        self.inbox.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Wire the passive-diagnostics registry (lsp-01). Set before `start` so the
    /// reader thread routes `publishDiagnostics` notifications into it from the
    /// first message. Safe to set to null to detach.
    pub fn setRegistry(self: *ServerInstance, reg: ?*registry_mod.Registry) void {
        self.registry = reg;
    }

    /// Wire the resolved server config (lsp-07). Set before `start` so the
    /// handshake splices `initializationOptions` / `workspaceFolder` and the
    /// startup timeout / restart cap are taken from the config. The config is
    /// owned by the caller and must outlive the instance.
    pub fn setConfig(self: *ServerInstance, cfg: ?*const config_mod.LspServerConfig) void {
        self.config = cfg;
        if (cfg) |c| {
            self.startup_timeout_ms = c.startup_timeout_ms;
            self.max_restarts = c.max_restarts;
        }
    }

    /// True when the server has completed its handshake and the reader is live.
    pub fn isRunning(self: *const ServerInstance) bool {
        return self.state == .running;
    }

    /// The child pid (POSIX) once spawned, else null. Used by tests to prove a
    /// server is reused (same pid) rather than re-spawned per request.
    pub fn pid(self: *const ServerInstance) ?std.process.Child.Id {
        if (self.child) |c| return c.id;
        return null;
    }

    /// Spawn + handshake. Idempotent when already running. On any failure the
    /// state is left at `error_state` and the child (if any) is killed.
    ///
    /// lsp-05 crash-recovery cap: if the instance is already in `error_state`
    /// after more than `max_restarts` unexpected exits, `start()` refuses with
    /// `error.MaxRestartsExceeded` rather than respawning a server that keeps
    /// dying. The handshake is bounded by `startup_timeout_ms` (a server that
    /// never answers `initialize` fails fast instead of hanging the caller).
    pub fn start(self: *ServerInstance) !void {
        if (self.state == .running) return;

        // lsp-05: stop restarting a server that has crashed too many times. The
        // check is `>` so a freshly-created instance (count 0) and the first few
        // recoveries are allowed; only past the cap do we refuse.
        if (self.state == .error_state and self.crash_recovery_count > self.max_restarts) {
            self.last_error = error.MaxRestartsExceeded;
            return error.MaxRestartsExceeded;
        }

        // lsp-05 restart-in-place: a prior crash leaves the dead reader thread
        // unjoined and the exited child still referenced. Reap both before
        // respawning so the new handshake uses fresh handles and no thread
        // handle leaks. The crashed reader has already returned, so the join is
        // immediate.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        self.killChild();
        self.drainInbox();

        self.state = .starting;
        self.last_error = null;
        self.stop_flag.store(false, .release);
        self.start_time = clock.nowMillisIo(self.io);
        self.restart_count += 1;

        var child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            self.state = .error_state;
            self.last_error = err;
            return err;
        };
        if (child.stdin == null or child.stdout == null) {
            child.kill(self.io);
            self.state = .error_state;
            self.last_error = error.MissingPipe;
            return error.MissingPipe;
        }
        self.child = child;

        // Start the reader BEFORE the handshake so the initialize response is
        // captured by the same inbox path everything else uses.
        self.reader_thread = std.Thread.spawn(.{}, readerMain, .{self}) catch |err| {
            self.killChild();
            self.state = .error_state;
            self.last_error = err;
            return err;
        };

        // initialize (id 1) then the `initialized` notification, bounded by the
        // startup timeout (lsp-05).
        self.handshake() catch |err| {
            // Tear the reader + child down so a failed handshake leaves no
            // zombie. stop() joins the reader and kills the child. stop() may
            // have already flipped the crash counter if the child died during
            // the handshake; do not double-count here.
            self.stop();
            self.state = .error_state;
            self.last_error = err;
            return err;
        };
        // Only promote to `running` if the reader thread has not already
        // observed a crash between the handshake completing and here (a stub
        // that exits right after `initialize` can hit EOF in this window).
        // Guard the read-modify-write with the inbox mutex, which the reader
        // also takes in failAllPending right after onCrash, so we never mask a
        // just-recorded crash.
        self.lockInbox();
        if (self.state == .starting) self.state = .running;
        self.unlockInbox();
    }

    fn handshake(self: *ServerInstance) !void {
        // lsp-11: the initialize params now advertise a rich, realistic
        // capability set (positionEncodings:["utf-16"], publishDiagnostics with
        // relatedInformation + tagSupport, hover markdown, definition.linkSupport,
        // hierarchical documentSymbol, callHierarchy, workspaceFolders) so servers
        // behave correctly. lsp-07 splices the config's `initializationOptions` /
        // `workspaceFolder` when a config is wired (the init-options are what
        // vue-language-server and similar servers need).
        const init_body = try self.buildInitBody();
        defer self.allocator.free(init_body);

        // lsp-05: bound the init round-trip by the startup timeout so a server
        // that never replies fails `start()` fast rather than hanging 30s (or
        // forever). Tests inject a short startup_timeout_ms for this path.
        const resp = try self.awaitResponseTimeout(1, init_body, self.startup_timeout_ms);
        self.allocator.free(resp);

        // lsp-11: the `initialized` notification is sent AFTER the init response
        // is received (some servers withhold diagnostics until they receive it).
        try self.writeFramed("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    }

    /// Build the `initialize` request body (lsp-02 framing, lsp-11 capabilities,
    /// lsp-07 config splice).
    ///
    /// The capability tree (lsp-11) advertises a realistic client so servers
    /// behave: `general.positionEncodings:["utf-16"]` (our 0-based line/character
    /// offsets are UTF-16 code units, matching the reference); `textDocument`
    /// capabilities for `publishDiagnostics` (with `relatedInformation` +
    /// `tagSupport` so deprecated/unnecessary tags survive), `hover` (markdown),
    /// `definition`/`implementation`/`references`/`typeDefinition` with
    /// `linkSupport`, hierarchical `documentSymbol`, and `callHierarchy`;
    /// `workspaceFolders:true`. `workspace.configuration` is declared `false`:
    /// we *handle* server-initiated `workspace/configuration` (lsp-09) but
    /// declaring false matches the reference and minimizes config requests.
    /// Mirrors the reference `InitializeParams` block (LSPServerInstance.ts:167-237).
    ///
    /// With a config (lsp-07) the params additionally carry `rootPath` /
    /// `rootUri` / `workspaceFolders` from `workspace_folder` and splice the
    /// already-validated `initializationOptions` JSON. The init-options string is
    /// produced by config.zig (a re-stringified `std.json.Value`), so it is always
    /// a single valid JSON value and is spliced verbatim. All path-derived strings
    /// are emitted via the stringifier, so a path containing quotes cannot break
    /// the JSON (avoiding the hand-rolled interpolation footgun).
    fn buildInitBody(self: *ServerInstance) ![]u8 {
        var buf = std_io.StringBuilder.init(self.allocator);
        defer buf.deinit();
        const w = buf.writer();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"processId\":{d}", .{std.c.getpid()});

        if (self.config) |c| {
            if (c.workspace_folder) |wf| {
                const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{wf});
                defer self.allocator.free(uri);
                try w.writeAll(",\"rootPath\":");
                try std.json.Stringify.value(wf, .{}, w);
                try w.writeAll(",\"rootUri\":");
                try std.json.Stringify.value(uri, .{}, w);
                try w.writeAll(",\"workspaceFolders\":[{\"uri\":");
                try std.json.Stringify.value(uri, .{}, w);
                try w.writeAll(",\"name\":");
                try std.json.Stringify.value(std.fs.path.basename(wf), .{}, w);
                try w.writeAll("}]");
            }
            if (c.initialization_options_json) |io_opts| {
                try w.writeAll(",\"initializationOptions\":");
                // io_opts is a validated, re-stringified JSON value -> splice it.
                try w.writeAll(io_opts);
            }
        }

        try w.writeAll(",\"capabilities\":");
        try w.writeAll(client_capabilities_json);
        try w.writeAll("}}");
        return buf.toOwnedSlice();
    }

    /// Send a request and block (polling) until the matching response body
    /// arrives, the timeout elapses, or the server crashes. Returns the
    /// response body owned by the caller.
    ///
    /// lsp-06 ContentModified retry: if the server replies with the transient
    /// ContentModified error (-32801, e.g. rust-analyzer still indexing on the
    /// first request to a fresh large project), the request is retried up to
    /// `protocol.MAX_RETRIES_FOR_TRANSIENT_ERRORS` times with exponential
    /// backoff (500/1000/2000ms via `backoff.delayMs`). The retry stays inside
    /// this persistent instance -- the same open server and any didOpen'd files
    /// are reused across attempts, which is the whole point: a fresh spawn per
    /// attempt would re-trigger indexing and never converge. Each attempt sends
    /// a fresh request id so a late response from a prior attempt can never be
    /// mismatched. On exhaustion the last (error-bearing) response is returned
    /// so the caller can surface the failure.
    pub fn sendRequest(self: *ServerInstance, method: []const u8, params_json: []const u8) ![]u8 {
        if (self.state != .running) return error.ServerNotRunning;

        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const id = self.next_id;
            self.next_id += 1;
            const body = try std.fmt.allocPrint(
                self.allocator,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
                .{ id, method, params_json },
            );
            defer self.allocator.free(body);

            const resp = try self.awaitResponse(id, body);

            // Classify the response: a transient ContentModified error is
            // retried with backoff; anything else (success or terminal error)
            // is returned to the caller as-is.
            const code = protocol.responseErrorCode(self.allocator, resp);
            if (protocol.isRetryableErrorCode(code) and attempt < protocol.MAX_RETRIES_FOR_TRANSIENT_ERRORS) {
                self.allocator.free(resp);
                const delay_ms = backoff.delayMs(attempt, backoff.BASE_DELAY_MS, backoff.MAX_DELAY_MS);
                // Project convention: route sleeps through the clock shim, not
                // std.time.sleep.
                clock.sleepNanos(delay_ms * std.time.ns_per_ms);
                continue;
            }
            return resp;
        }
    }

    /// Send a JSON-RPC notification (no id, no response expected). Used by the
    /// document-sync path (lsp-04: didOpen/didChange/didSave/didClose) where the
    /// server reacts (e.g. re-diagnoses) but never replies. `params_json` is the
    /// already-serialized params object, e.g. `{"textDocument":{...}}`.
    pub fn sendNotification(self: *ServerInstance, method: []const u8, params_json: []const u8) !void {
        if (self.state != .running) return error.ServerNotRunning;
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(body);
        try self.writeFramed(body);
    }

    /// Register `id` in the inbox, write the framed body, and poll for delivery
    /// using the default request timeout. Shared by `sendRequest`.
    fn awaitResponse(self: *ServerInstance, id: i64, body: []const u8) ![]u8 {
        return self.awaitResponseTimeout(id, body, REQUEST_TIMEOUT_MS);
    }

    /// Like `awaitResponse` but with an explicit timeout in ms (lsp-05 uses this
    /// for the bounded init handshake). Returns `error.Timeout` if no matching
    /// response arrives, `error.ServerCrashed` if the reader marks the inbox
    /// failed (EOF / crash) first.
    fn awaitResponseTimeout(self: *ServerInstance, id: i64, body: []const u8, timeout_ms: i64) ![]u8 {
        self.lockInbox();
        self.inbox.put(self.allocator, id, .{}) catch {
            self.unlockInbox();
            return error.OutOfMemory;
        };
        self.unlockInbox();

        self.writeFramed(body) catch |err| {
            self.lockInbox();
            _ = self.inbox.remove(id);
            self.unlockInbox();
            return err;
        };

        const deadline = clock.nowMillisIo(self.io) + timeout_ms;
        while (true) {
            self.lockInbox();
            if (self.inbox.getPtr(id)) |entry| {
                if (entry.failed) {
                    _ = self.inbox.remove(id);
                    self.unlockInbox();
                    return error.ServerCrashed;
                }
                if (entry.body) |b| {
                    _ = self.inbox.remove(id);
                    self.unlockInbox();
                    return b; // ownership transfers to caller
                }
            }
            self.unlockInbox();

            if (clock.nowMillisIo(self.io) >= deadline) {
                self.lockInbox();
                _ = self.inbox.remove(id);
                self.unlockInbox();
                return error.Timeout;
            }
            clock.sleepNanos(POLL_SLICE_NS);
        }
    }

    fn lockInbox(self: *ServerInstance) void {
        self.inbox_mutex.lock(self.io) catch {};
    }
    fn unlockInbox(self: *ServerInstance) void {
        self.inbox_mutex.unlock(self.io);
    }

    /// Write a framed message to the child's stdin under the write mutex.
    fn writeFramed(self: *ServerInstance, body: []const u8) !void {
        const framed = try protocol.frame(self.allocator, body);
        defer self.allocator.free(framed);
        self.write_mutex.lock(self.io) catch {};
        defer self.write_mutex.unlock(self.io);
        const child = self.child orelse return error.ServerNotRunning;
        const stdin = child.stdin orelse return error.ServerNotRunning;
        try stdin.writeStreamingAll(self.io, framed);
    }

    /// Background reader: frame messages off stdout and route them. Exits on
    /// EOF (server closed stdout -> crash/exit) or when `stop_flag` is set and
    /// a read returns. Marks all pending inbox entries failed on EOF so blocked
    /// callers wake.
    ///
    /// lsp-05 crash detection: when the loop ends because of an unexpected EOF
    /// (the `stop_flag` is NOT set, i.e. nobody asked us to stop) the child must
    /// have exited / crashed. Flip the instance to `error_state` and bump
    /// `crash_recovery_count`, mirroring the reference's `onCrash` callback
    /// (LSPClient.ts:156-167). A deliberate `stop()` already set the flag, so
    /// that path does not count as a crash.
    fn readerMain(self: *ServerInstance) void {
        const child = self.child orelse return;
        const stdout = child.stdout orelse return;
        while (!self.stop_flag.load(.acquire)) {
            const frame_body = protocol.readFrame(self.allocator, stdout, self.io, MAX_FRAME_BYTES) catch {
                break; // EOF or framing error -> stop reading
            };
            self.dispatch(frame_body);
        }
        // If we are exiting because of an unexpected EOF (not a deliberate
        // stop()), record a crash so ensureServerStarted can bounded-restart it.
        if (!self.stop_flag.load(.acquire)) {
            self.onCrash();
        }
        // Stream ended: wake any blocked callers with a failure so they do not
        // hang until their timeout.
        self.failAllPending();
    }

    /// Record an unexpected exit (lsp-05). Transitions to `error_state` and
    /// increments the crash counter. The reader thread is the sole caller, once
    /// per exit. The state write is under the inbox mutex so it serializes with
    /// `start`'s `.starting -> .running` promotion (neither masks the other).
    /// State is set BEFORE the counter is bumped so an observer that polls the
    /// counter (e.g. a restart loop) sees the matching `error_state` once the
    /// count has moved -- never a `running` state with an already-incremented
    /// count, which would let a restart slip through as a no-op early-return.
    fn onCrash(self: *ServerInstance) void {
        self.last_error = error.ServerCrashed;
        self.lockInbox();
        self.state = .error_state;
        self.unlockInbox();
        self.crash_recovery_count += 1;
    }

    /// Route one framed-stripped message body. Takes ownership of `body`: for
    /// responses it is stored in the inbox (transferred to the waiter); for
    /// notifications / server requests it is freed after handling.
    fn dispatch(self: *ServerInstance, body: []u8) void {
        const msg = protocol.classify(self.allocator, body) catch {
            self.allocator.free(body);
            return;
        } orelse {
            // Malformed JSON: drop, never crash the reader loop.
            self.allocator.free(body);
            return;
        };
        defer if (msg.method) |m| self.allocator.free(m);

        switch (msg.kind()) {
            .response => {
                const id = msg.id orelse {
                    self.allocator.free(body);
                    return;
                };
                self.lockInbox();
                defer self.unlockInbox();
                if (self.inbox.getPtr(id)) |entry| {
                    // Replace any prior body (should not happen) to avoid a leak.
                    if (entry.body) |old| self.allocator.free(old);
                    entry.body = body; // ownership moves into the inbox
                } else {
                    // No waiter (e.g. late response after timeout): drop.
                    self.allocator.free(body);
                }
            },
            .notification => {
                if (msg.method) |m| {
                    // lsp-01: passive diagnostics. Parse the publish and route it
                    // into the registry so the next turn can inject it. Malformed
                    // params are dropped (never crash the reader loop).
                    if (self.registry != null and std.mem.eql(u8, m, "textDocument/publishDiagnostics")) {
                        handlePublishDiagnostics(self.allocator, self.registry.?, self.name, body);
                    }
                    if (self.notify_fn) |f| f(self.notify_ctx, self.name, m, body);
                }
                self.allocator.free(body);
            },
            .server_request => {
                // lsp-09: reply to server-initiated requests so the server does
                // not stall waiting for an answer (an unanswered request is the
                // stall - this is the likely cause of empty TypeScript results
                // today). `workspace/configuration` is answered with one `null`
                // per requested item; any other server request gets `result:null`.
                // The reply must go out on the same stdin `sendRequest` writes to,
                // so writeFramed's write_mutex serializes the two writers.
                const id = msg.id orelse {
                    self.allocator.free(body);
                    return;
                };
                const method = msg.method orelse {
                    self.allocator.free(body);
                    return;
                };
                const reply = buildServerRequestReply(self.allocator, id, method, body) catch {
                    // Out of memory building the reply: drop rather than crash the
                    // reader loop. The request stays unanswered (the pre-lsp-09
                    // behavior) only in this degenerate case.
                    self.allocator.free(body);
                    return;
                };
                defer self.allocator.free(reply);
                // Best-effort: a write failure (server already gone) must not
                // crash the reader loop.
                self.writeFramed(reply) catch {};
                self.allocator.free(body);
            },
        }
    }

    fn failAllPending(self: *ServerInstance) void {
        self.lockInbox();
        defer self.unlockInbox();
        var it = self.inbox.iterator();
        while (it.next()) |e| {
            e.value_ptr.failed = true;
        }
    }

    /// Clear all inbox entries, freeing any unclaimed response bodies. Called on
    /// the restart-in-place path (lsp-05) so a respawn starts with a clean inbox
    /// rather than stale failed/leftover entries from the prior crash. The
    /// `next_id` counter is intentionally NOT reset: ids stay monotonic across
    /// restarts so a late response from a dead child can never alias a new id.
    fn drainInbox(self: *ServerInstance) void {
        self.lockInbox();
        defer self.unlockInbox();
        var it = self.inbox.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.body) |b| self.allocator.free(b);
        }
        self.inbox.clearRetainingCapacity();
    }

    fn killChild(self: *ServerInstance) void {
        if (self.child) |*c| {
            // 0.16 footgun: kill reaps internally; do NOT call wait() after.
            c.kill(self.io);
            self.child = null;
        }
    }

    /// Stop the server: signal the reader, close stdin (so the server sees EOF
    /// and exits), kill the child as a fallback, join the reader thread, and
    /// transition to `stopped`. Idempotent. Swallows all errors (matches the
    /// reference, which swallows per-server errors on shutdown).
    pub fn stop(self: *ServerInstance) void {
        if (self.state == .stopped) return;
        self.state = .stopping;
        self.stop_flag.store(true, .release);

        // Closing stdin makes a well-behaved server exit and lets the reader
        // hit EOF; kill() is the hard fallback.
        if (self.child) |*c| {
            if (c.stdin) |stdin| {
                stdin.close(self.io);
                c.stdin = null;
            }
        }
        self.killChild();

        // Join the reader AFTER killing so its blocking read returns. Joining
        // before freeing the inbox avoids the reader writing into freed memory.
        if (self.reader_thread) |t| {
            t.join();
            self.reader_thread = null;
        }
        self.state = .stopped;
    }
};

/// Parse a `textDocument/publishDiagnostics` notification body and route it into
/// `reg` (lsp-01). Exposed as a plain function (not a method) so a unit test can
/// drive the reader-dispatch behavior directly with a hand-built params JSON,
/// decoupling the assertion from background-thread timing. Drops malformed
/// params silently -- the reference rejects params missing `uri`/`diagnostics`
/// and the reader loop must never crash on a bad publish.
pub fn handlePublishDiagnostics(
    allocator: std.mem.Allocator,
    reg: *registry_mod.Registry,
    server_name: []const u8,
    body: []const u8,
) void {
    var parsed = (registry_mod.parsePublishDiagnostics(allocator, body) catch return) orelse return;
    defer parsed.deinit(allocator);
    // registerPending dupes into the registry allocator, so the parsed slice is
    // freed by the defer above. An empty diagnostics set clears the URI.
    reg.registerPending(server_name, parsed.uri, parsed.diags) catch {};
}

/// Build the JSON-RPC response body for a server-initiated request (lsp-09).
/// Mirrors the reference's `instance.onRequest('workspace/configuration', params
/// => params.items.map(() => null))` (LSPServerManager.ts:123-135): a
/// `workspace/configuration` request is answered with an array holding one
/// `null` per requested item, so servers like TypeScript do not stall waiting
/// for a reply. Any other server request gets `result:null` -- the point is that
/// an unanswered request IS the stall, so nothing is left dangling.
///
/// `id` and `method` come from the already-`classify`d message; `body` is the
/// raw request frame (framing stripped), re-parsed only to count
/// `params.items`. Exposed as a plain function (not a method) so a unit test can
/// drive it with a hand-built request frame and assert the response frame it
/// would write, with no live server (matches the lsp-09 test strategy). Returns
/// an owned slice allocated by `allocator`; the caller frames + writes it.
pub fn buildServerRequestReply(
    allocator: std.mem.Allocator,
    id: i64,
    method: []const u8,
    body: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        const n = countConfigurationItems(allocator, body);
        var buf = std_io.StringBuilder.init(allocator);
        defer buf.deinit();
        const w = buf.writer();
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":[", .{id});
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("null");
        }
        try w.writeAll("]}");
        return buf.toOwnedSlice();
    }
    // Any other server request: reply with a null result so nothing stalls.
    return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}", .{id});
}

/// Count the entries in a `workspace/configuration` request's `params.items`
/// array. Returns 0 on malformed params (the reply is then an empty array,
/// which is a valid response that does not stall the server). Pure: parses with
/// a throwaway arena and reads nothing back out, so no lifetime concerns.
fn countConfigurationItems(allocator: std.mem.Allocator, body: []const u8) usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const params = parsed.value.object.get("params") orelse return 0;
    if (params != .object) return 0;
    const items = params.object.get("items") orelse return 0;
    if (items != .array) return 0;
    return items.array.items.len;
}

// --- Tests ---

const testing = std.testing;
const test_helpers = @import("../test_helpers.zig");

/// Python stub LSP server: frames messages by Content-Length, answers
/// `initialize` (id 1), and echoes any other request id back as a result that
/// names the method. Lets the tests prove handshake + id-matched round trips
/// without a real language server. Skipped under CI (python3 may be absent).
const stub_server_py =
    \\import json, sys
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\while True:
    \\    m = read_frame()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

fn writeStub(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "stub.py", .data = stub_server_py });
    return test_helpers.tmpDirPath(testing.allocator, tmp, "stub.py");
}

test "ServerInstance round-trips two id-matched requests through the reader" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try writeStub(&tmp);
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    const r1 = try inst.sendRequest("textDocument/hover", "{}");
    defer testing.allocator.free(r1);
    const r2 = try inst.sendRequest("textDocument/definition", "{}");
    defer testing.allocator.free(r2);

    // Each response must name its own method (proves ids were matched, not
    // crossed).
    try testing.expect(std.mem.indexOf(u8, r1, "textDocument/hover") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "textDocument/definition") != null);
}

test "ServerInstance stop transitions to stopped and is idempotent" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try writeStub(&tmp);
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    inst.stop();
    try testing.expectEqual(State.stopped, inst.state);
    try testing.expect(!inst.isRunning());
    // Second stop is a no-op.
    inst.stop();
    try testing.expectEqual(State.stopped, inst.state);
}

// --- lsp-05: lifecycle state machine, crash recovery, restart cap, timeout ---

/// Stub that answers `initialize`, consumes the follow-up `initialized`
/// notification (so the handshake's `initialized` write does not race a closed
/// pipe and the instance reliably reaches `running`), then exits, simulating a
/// server crash right after startup. The reader thread sees EOF and must flip
/// the instance to `error_state` + bump the crash counter.
const crash_after_init_py =
    \\import json, sys
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\m = read_frame()
    \\if m is not None and m.get("method") == "initialize":
    \\    write_frame({"jsonrpc":"2.0","id":m.get("id"),"result":{"capabilities":{}}})
    \\# Consume the `initialized` notification so the parent's handshake write
    \\# completes and the instance reaches `running` before we exit.
    \\read_frame()
    \\# Exit now -> the parent reader hits EOF while the instance is `running`.
    \\sys.exit(0)
;

/// Stub that reads the `initialize` request but never replies, so the bounded
/// startup handshake must time out. Sleeps to stay alive past the (short,
/// test-injected) timeout.
const hang_on_init_py =
    \\import sys, time
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    return sys.stdin.buffer.read(length)
    \\read_frame()
    \\# Never reply; just stay alive so start() must time out, not see an EOF.
    \\time.sleep(30)
;

/// Poll until `inst.crash_recovery_count` reaches at least `want` (the reader
/// thread bumps it asynchronously after EOF) or attempts run out. Returns the
/// observed count.
fn waitForCrashCount(inst: *ServerInstance, want: u32) u32 {
    var attempts: usize = 0;
    while (attempts < 400) : (attempts += 1) {
        if (inst.crash_recovery_count >= want) return inst.crash_recovery_count;
        clock.sleepNanos(5 * std.time.ns_per_ms);
    }
    return inst.crash_recovery_count;
}

test "lsp-05 crash after init flips to error_state and increments crash count" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "crash.py", .data = crash_after_init_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "crash.py");
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    // The handshake itself succeeds (initialize is answered), so start returns
    // ok; the crash is observed by the reader right after.
    try inst.start();

    const count = waitForCrashCount(inst, 1);
    try testing.expect(count >= 1);
    try testing.expectEqual(State.error_state, inst.state);
    try testing.expect(!inst.isRunning());
}

test "lsp-05 start refuses after maxRestarts crash recoveries" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "crash.py", .data = crash_after_init_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "crash.py");
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();
    // Lower the cap so the test is quick: 2 recoveries allowed, the 3rd start
    // (after the cap is exceeded) must refuse.
    inst.max_restarts = 2;

    // Crash recovery 1.
    try inst.start();
    _ = waitForCrashCount(inst, 1);
    // Crash recovery 2 (count==2, still == cap so a restart is allowed).
    try inst.start();
    _ = waitForCrashCount(inst, 2);
    // Crash recovery 3 (count==3 > cap of 2).
    try inst.start();
    _ = waitForCrashCount(inst, 3);

    // Now count (3) exceeds max_restarts (2): start must refuse.
    try testing.expectError(error.MaxRestartsExceeded, inst.start());
    try testing.expectEqual(@as(?anyerror, error.MaxRestartsExceeded), inst.last_error);
}

test "lsp-05 start fails with timeout when initialize is never answered" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "hang.py", .data = hang_on_init_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "hang.py");
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();
    // Short injected startup timeout so the test does not block for 30s.
    inst.startup_timeout_ms = 300;

    try testing.expectError(error.Timeout, inst.start());
    try testing.expectEqual(State.error_state, inst.state);
    try testing.expect(!inst.isRunning());
}

test "lsp-05 clean start/shutdown walks stopped -> running -> stopped" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try writeStub(&tmp);
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try testing.expectEqual(State.stopped, inst.state);
    try inst.start();
    try testing.expectEqual(State.running, inst.state);
    inst.stop();
    try testing.expectEqual(State.stopped, inst.state);
    // A clean stop is not a crash.
    try testing.expectEqual(@as(u32, 0), inst.crash_recovery_count);
}

// --- lsp-01: passive diagnostics dispatch ---

test "handlePublishDiagnostics routes a synthetic publish into the registry and renders it" {
    rt.installForTest();
    var reg = registry_mod.Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const body =
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///proj/foo.zig\",\"diagnostics\":[" ++
        "{\"range\":{\"start\":{\"line\":2,\"character\":0},\"end\":{\"line\":2,\"character\":4}},\"severity\":1,\"message\":\"type mismatch\"}" ++
        "]}}";
    handlePublishDiagnostics(testing.allocator, &reg, "zls", body);

    const out = (try reg.checkForDiagnostics(testing.allocator)).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Error") != null);
    try testing.expect(std.mem.indexOf(u8, out, "foo.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out, "type mismatch") != null);
}

test "handlePublishDiagnostics with an empty set clears pending for the uri" {
    rt.installForTest();
    var reg = registry_mod.Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    handlePublishDiagnostics(
        testing.allocator,
        &reg,
        "zls",
        "{\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///c.zig\",\"diagnostics\":[" ++
            "{\"range\":{\"start\":{\"line\":0,\"character\":0}},\"severity\":1,\"message\":\"x\"}]}}",
    );
    // A follow-up empty publish for the same URI means the file is now clean.
    handlePublishDiagnostics(
        testing.allocator,
        &reg,
        "zls",
        "{\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"file:///c.zig\",\"diagnostics\":[]}}",
    );
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}

test "handlePublishDiagnostics drops malformed params without crashing" {
    rt.installForTest();
    var reg = registry_mod.Registry.init(testing.allocator, rt.io);
    defer reg.deinit();
    handlePublishDiagnostics(testing.allocator, &reg, "zls", "garbage not json");
    handlePublishDiagnostics(testing.allocator, &reg, "zls", "{\"params\":{}}");
    try testing.expect((try reg.checkForDiagnostics(testing.allocator)) == null);
}

/// Stub LSP server that, in addition to the round-trip behavior, emits a
/// `textDocument/publishDiagnostics` notification (one Error in foo.zig) right
/// after it receives the `initialized` notification. Lets the end-to-end test
/// prove a passive publish flows reader-thread -> registry without a tool call.
const diag_stub_server_py =
    \\import json, sys
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\while True:
    \\    m = read_frame()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        write_frame({"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///proj/foo.zig","diagnostics":[{"range":{"start":{"line":3,"character":1},"end":{"line":3,"character":5}},"severity":1,"message":"undefined symbol"}]}})
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

test "ServerInstance delivers a passive publishDiagnostics into the registry end to end" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "diag_stub.py", .data = diag_stub_server_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "diag_stub.py");
    defer testing.allocator.free(script);

    var reg = registry_mod.Registry.init(testing.allocator, rt.io);
    defer reg.deinit();

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();
    inst.setRegistry(&reg);

    try inst.start();
    try testing.expect(inst.isRunning());

    // Drive a round-trip request so we know the reader thread has processed at
    // least one message after `initialized`; the publish is emitted right after
    // `initialized`, so by the time this request's response returns it has been
    // dispatched. Poll briefly in case the publish lands a touch later.
    const r = try inst.sendRequest("textDocument/hover", "{}");
    testing.allocator.free(r);

    var attempts: usize = 0;
    var got: ?[]u8 = null;
    while (attempts < 50) : (attempts += 1) {
        got = try reg.checkForDiagnostics(testing.allocator);
        if (got != null) break;
        clock.sleepNanos(5 * std.time.ns_per_ms);
    }
    try testing.expect(got != null);
    defer testing.allocator.free(got.?);
    try testing.expect(std.mem.indexOf(u8, got.?, "undefined symbol") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "foo.zig") != null);
}

// --- lsp-06: ContentModified (-32801) transient-error retry with backoff ---

/// Stub LSP server that answers `initialize`, then for every other request
/// returns ContentModified (-32801) for the FIRST TWO non-initialize requests
/// and a real result on the third+. Proves `sendRequest` retries past the
/// transient error and ultimately returns the result. The retry count lives in
/// the stub (it keeps the same persistent process across attempts, which is the
/// behavior lsp-06 must preserve -- a fresh spawn per attempt would reset it).
const content_modified_then_ok_py =
    \\import json, sys
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\reqs = 0
    \\while True:
    \\    m = read_frame()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif mid is not None:
    \\        reqs += 1
    \\        if reqs <= 2:
    \\            write_frame({"jsonrpc":"2.0","id":mid,"error":{"code":-32801,"message":"content modified"}})
    \\        else:
    \\            write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method,"attempts":reqs}})
;

test "lsp-06 sendRequest retries past ContentModified and returns the result" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "cm.py", .data = content_modified_then_ok_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "cm.py");
    defer testing.allocator.free(script);

    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    // First two non-initialize requests get -32801; sendRequest must retry and
    // return the success result from the third attempt (same persistent server).
    const r = try inst.sendRequest("textDocument/hover", "{}");
    defer testing.allocator.free(r);
    try testing.expect(std.mem.indexOf(u8, r, "echoed") != null);
    try testing.expect(std.mem.indexOf(u8, r, "textDocument/hover") != null);
    // The error code must NOT be present in the final returned body.
    try testing.expect(std.mem.indexOf(u8, r, "-32801") == null);
}

test "lsp-06 backoff schedule is 500/1000/2000ms for the first three retries" {
    // Asserts the computed delays the retry loop uses (do not actually sleep in
    // CI). The retry loop calls `backoff.delayMs(attempt, BASE_DELAY_MS,
    // MAX_DELAY_MS)` with attempt 0,1,2,... matching the reference's
    // 500 * 2^attempt schedule.
    try testing.expectEqual(@as(u64, 500), backoff.delayMs(0, backoff.BASE_DELAY_MS, backoff.MAX_DELAY_MS));
    try testing.expectEqual(@as(u64, 1000), backoff.delayMs(1, backoff.BASE_DELAY_MS, backoff.MAX_DELAY_MS));
    try testing.expectEqual(@as(u64, 2000), backoff.delayMs(2, backoff.BASE_DELAY_MS, backoff.MAX_DELAY_MS));
}

// --- lsp-07: plugin-sourced config reaches the initialize params ------------

/// Stub LSP server that writes the FULL `initialize` request body it receives
/// to the file named in argv[1], then answers the handshake normally. Lets the
/// lsp-07 test prove the config's `initializationOptions` were spliced into the
/// init params (not just the method name).
const record_init_stub_py =
    \\import json, sys
    \\record_path = sys.argv[1]
    \\def read_raw():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    return sys.stdin.buffer.read(length)
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\while True:
    \\    raw = read_raw()
    \\    if raw is None: break
    \\    m = json.loads(raw.decode("utf-8"))
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method == "initialize":
    \\        with open(record_path, "wb") as f:
    \\            f.write(raw); f.flush()
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

test "lsp-07 config initializationOptions reach the initialize params" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "recinit.py", .data = record_init_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "recinit.py");
    defer testing.allocator.free(script);
    // Pre-create the record file so tmpDirPath (realpath) resolves it.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "init.json", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "init.json");
    defer testing.allocator.free(record_abs);

    // Build a config carrying initializationOptions + a workspaceFolder, as a
    // vue-language-server-style plugin entry would (parsed via config.zig).
    const manifest =
        \\{"lspServers":[{
        \\  "name":"vue-language-server",
        \\  "workspaceFolder":"/proj/app",
        \\  "extensionToLanguage":{".vue":"vue"},
        \\  "initializationOptions":{"typescript":{"tsdk":"/usr/lib/tsdk"}}
        \\}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest, .{});
    defer parsed.deinit();
    const configs = try config_mod.LspServerConfig.parseManifestArray(testing.allocator, parsed.value.object.get("lspServers"));
    defer config_mod.freeServers(testing.allocator, configs);
    try testing.expectEqual(@as(usize, 1), configs.len);

    const argv = [_][]const u8{ "python3", script, record_abs };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "vue-language-server", &argv);
    defer inst.destroy();
    inst.setConfig(&configs[0]);

    try inst.start();
    try testing.expect(inst.isRunning());

    // Read back the captured init frame and assert the spliced fields.
    var attempts: usize = 0;
    var data: []u8 = undefined;
    var got = false;
    while (attempts < 200) : (attempts += 1) {
        data = tmp.dir.readFileAlloc(rt.io, "init.json", testing.allocator, .limited(64 * 1024)) catch {
            clock.sleepNanos(3 * std.time.ns_per_ms);
            continue;
        };
        if (data.len > 0) {
            got = true;
            break;
        }
        testing.allocator.free(data);
        clock.sleepNanos(3 * std.time.ns_per_ms);
    }
    try testing.expect(got);
    defer testing.allocator.free(data);

    try testing.expect(std.mem.indexOf(u8, data, "\"initializationOptions\":") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"tsdk\":\"/usr/lib/tsdk\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "\"workspaceFolders\":") != null);
    try testing.expect(std.mem.indexOf(u8, data, "file:///proj/app") != null);
    // The init frame must still be valid JSON.
    var p2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, data, .{});
    defer p2.deinit();
    try testing.expect(p2.value == .object);

    // The config also propagated the lifecycle knobs onto the instance.
    try testing.expectEqual(config_mod.DEFAULT_MAX_RESTARTS, inst.max_restarts);
}

// --- lsp-09: workspace/configuration reverse-request handler ----------------

test "lsp-09 workspace/configuration reply has one null per item with matching id" {
    rt.installForTest();
    const a = testing.allocator;
    // A server-initiated request with 3 config items: the reply must be a
    // 3-element null array keyed by the request id, so the server does not stall.
    const body =
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"workspace/configuration\",\"params\":{\"items\":[" ++
        "{\"section\":\"typescript\"},{\"section\":\"javascript\"},{\"section\":\"vue\"}]}}";
    const reply = try buildServerRequestReply(a, 7, "workspace/configuration", body);
    defer a.free(reply);

    // Exact-shape assertion (the reference returns params.items.map(() => null)).
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":[null,null,null]}",
        reply,
    );

    // And it must parse back to a 3-element array result with the right id.
    var parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
    const result = parsed.value.object.get("result").?;
    try testing.expectEqual(@as(usize, 3), result.array.items.len);
    for (result.array.items) |item| try testing.expect(item == .null);
}

test "lsp-09 workspace/configuration with zero items replies with an empty array" {
    rt.installForTest();
    const a = testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/configuration\",\"params\":{\"items\":[]}}";
    const reply = try buildServerRequestReply(a, 2, "workspace/configuration", body);
    defer a.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[]}", reply);
}

test "lsp-09 workspace/configuration with malformed params replies with an empty array" {
    rt.installForTest();
    const a = testing.allocator;
    // No `params.items` array at all -> count is 0 -> empty-array reply (valid,
    // does not stall) rather than a crash.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"workspace/configuration\",\"params\":{}}";
    const reply = try buildServerRequestReply(a, 4, "workspace/configuration", body);
    defer a.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":[]}", reply);
}

test "lsp-09 an unknown server request gets a result:null reply (no stall)" {
    rt.installForTest();
    const a = testing.allocator;
    const body = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"workspace/applyEdit\",\"params\":{\"edit\":{}}}";
    const reply = try buildServerRequestReply(a, 11, "workspace/applyEdit", body);
    defer a.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":null}", reply);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, reply, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 11), parsed.value.object.get("id").?.integer);
    try testing.expect(parsed.value.object.get("result").? == .null);
}

/// Stub LSP server for the lsp-09 end-to-end path. After it receives the
/// `initialized` notification it sends a server-initiated
/// `workspace/configuration` request (id 100, 2 items) and then BLOCKS reading
/// the reply frame. If the reply never arrives (the stall lsp-09 prevents), the
/// stub hangs and the round-trip request below never gets answered, so the test
/// would time out. With lsp-09 wired, the reader thread answers the reverse
/// request, the stub unblocks, and the follow-up request is answered normally.
const reverse_request_stub_py =
    \\import json, sys
    \\record_path = sys.argv[1]
    \\def note(tag):
    \\    with open(record_path, "a") as f:
    \\        f.write(tag + "\n"); f.flush()
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\while True:
    \\    m = read_frame()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        # Send a server-initiated request and BLOCK on its reply. If the
    \\        # parent never answers (the stall), the next read_frame hangs forever.
    \\        write_frame({"jsonrpc":"2.0","id":100,"method":"workspace/configuration","params":{"items":[{"section":"a"},{"section":"b"}]}})
    \\        reply = read_frame()
    \\        if reply is None: break
    \\        # Record the reply we got so the test can assert its shape.
    \\        if reply.get("id") == 100 and reply.get("result") == [None, None]:
    \\            note("rev-ok")
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

// --- lsp-11: rich client capabilities + initialization ----------------------

test "lsp-11 buildInitBody advertises a rich capability set" {
    // Pure unit test: assert the structured capabilities in the init body
    // directly, with no live server. Reuses the same buildInitBody the
    // handshake sends.
    rt.installForTest();
    const argv = [_][]const u8{"noop"};
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    const body = try inst.buildInitBody();
    defer testing.allocator.free(body);

    // The reference's capability keys the lsp-11 acceptance criteria name.
    try testing.expect(std.mem.indexOf(u8, body, "\"workspaceFolders\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"positionEncodings\":[\"utf-16\"]") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"publishDiagnostics\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"tagSupport\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"linkSupport\":true") != null);
    // relatedInformation + hierarchical documentSymbol + callHierarchy too.
    try testing.expect(std.mem.indexOf(u8, body, "\"relatedInformation\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"hierarchicalDocumentSymbolSupport\":true") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"callHierarchy\":") != null);
    // workspace.configuration declared false (we handle it via lsp-09 but match
    // the reference's declaration).
    try testing.expect(std.mem.indexOf(u8, body, "\"configuration\":false") != null);

    // The whole init body must still be valid JSON (no broken interpolation).
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    const params = parsed.value.object.get("params").?;
    try testing.expect(params == .object);
    const caps = params.object.get("capabilities").?;
    try testing.expect(caps == .object);
}

test "lsp-11 capture init frame contains the rich capabilities end to end" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "recinit.py", .data = record_init_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "recinit.py");
    defer testing.allocator.free(script);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "init.json", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "init.json");
    defer testing.allocator.free(record_abs);

    const argv = [_][]const u8{ "python3", script, record_abs };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    var attempts: usize = 0;
    var data: []u8 = undefined;
    var got = false;
    while (attempts < 200) : (attempts += 1) {
        data = tmp.dir.readFileAlloc(rt.io, "init.json", testing.allocator, .limited(64 * 1024)) catch {
            clock.sleepNanos(3 * std.time.ns_per_ms);
            continue;
        };
        if (data.len > 0) {
            got = true;
            break;
        }
        testing.allocator.free(data);
        clock.sleepNanos(3 * std.time.ns_per_ms);
    }
    try testing.expect(got);
    defer testing.allocator.free(data);

    try testing.expect(std.mem.indexOf(u8, data, "workspaceFolders") != null);
    try testing.expect(std.mem.indexOf(u8, data, "positionEncodings") != null);
    try testing.expect(std.mem.indexOf(u8, data, "publishDiagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, data, "tagSupport") != null);
    try testing.expect(std.mem.indexOf(u8, data, "linkSupport") != null);
}

/// Stub LSP server for the lsp-11 `initialized`-ordering test. Appends the
/// method name of every framed message it receives to the log file in argv[1],
/// one per line, then answers `initialize` normally. Lets the test prove the
/// `initialized` notification is sent AFTER the `initialize` request (the order
/// matters: some servers withhold diagnostics until they see `initialized`).
const record_methods_stub_py =
    \\import json, sys
    \\log_path = sys.argv[1]
    \\def read_frame():
    \\    header = b""
    \\    while b"\r\n\r\n" not in header:
    \\        c = sys.stdin.buffer.read(1)
    \\        if not c:
    \\            return None
    \\        header += c
    \\    length = 0
    \\    for line in header.decode("utf-8","replace").split("\r\n"):
    \\        if line.lower().startswith("content-length:"):
    \\            length = int(line.split(":",1)[1].strip()); break
    \\    body = sys.stdin.buffer.read(length)
    \\    return json.loads(body.decode("utf-8"))
    \\def write_frame(obj):
    \\    b = json.dumps(obj).encode("utf-8")
    \\    sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(b)).encode("utf-8"))
    \\    sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
    \\while True:
    \\    m = read_frame()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    mid = m.get("id")
    \\    if method is not None:
    \\        with open(log_path, "a") as f:
    \\            f.write(method + "\n"); f.flush()
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

test "lsp-11 initialized notification is sent after the init response" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "recmeth.py", .data = record_methods_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "recmeth.py");
    defer testing.allocator.free(script);
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "methods.log", .data = "" });
    const log_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "methods.log");
    defer testing.allocator.free(log_abs);

    const argv = [_][]const u8{ "python3", script, log_abs };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    // Poll the log until both `initialize` and `initialized` have been recorded.
    var attempts: usize = 0;
    var data: []u8 = undefined;
    var got_both = false;
    while (attempts < 300) : (attempts += 1) {
        data = tmp.dir.readFileAlloc(rt.io, "methods.log", testing.allocator, .limited(8192)) catch {
            clock.sleepNanos(3 * std.time.ns_per_ms);
            continue;
        };
        if (std.mem.indexOf(u8, data, "initialized") != null and
            std.mem.indexOf(u8, data, "initialize\n") != null)
        {
            got_both = true;
            break;
        }
        testing.allocator.free(data);
        clock.sleepNanos(3 * std.time.ns_per_ms);
    }
    try testing.expect(got_both);
    defer testing.allocator.free(data);

    // `initialize` must appear before `initialized` (order is load-bearing).
    const init_idx = std.mem.indexOf(u8, data, "initialize\n").?;
    const initialized_idx = std.mem.indexOf(u8, data, "initialized\n").?;
    try testing.expect(init_idx < initialized_idx);
}

test "lsp-09 reader thread answers a server-initiated workspace/configuration request end to end" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rev.py", .data = reverse_request_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rev.py");
    defer testing.allocator.free(script);
    // Pre-create the record file so the stub can append the rev-ok marker.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rev.log", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rev.log");
    defer testing.allocator.free(record_abs);

    const argv = [_][]const u8{ "python3", script, record_abs };
    const inst = try ServerInstance.create(testing.allocator, rt.io, "stub", &argv);
    defer inst.destroy();

    try inst.start();
    try testing.expect(inst.isRunning());

    // Right after `initialized` the stub emits a server-initiated
    // `workspace/configuration` request and BLOCKS reading its reply. With
    // lsp-09 wired, the reader thread answers it with `[null,null]`, the stub
    // unblocks and records the `rev-ok` marker. Without lsp-09 the request stays
    // unanswered (the stall) and the marker never appears. Poll the marker file
    // rather than driving a follow-up round-trip request, so the assertion is
    // purely about the reverse-request reply having reached the server.
    var attempts: usize = 0;
    var saw_ok = false;
    while (attempts < 400) : (attempts += 1) {
        const data = tmp.dir.readFileAlloc(rt.io, "rev.log", testing.allocator, .limited(4096)) catch {
            clock.sleepNanos(5 * std.time.ns_per_ms);
            continue;
        };
        defer testing.allocator.free(data);
        if (std.mem.indexOf(u8, data, "rev-ok") != null) {
            saw_ok = true;
            break;
        }
        clock.sleepNanos(5 * std.time.ns_per_ms);
    }
    try testing.expect(saw_ok);
}
