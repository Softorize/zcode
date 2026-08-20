//! Process-lifetime LSP server manager singleton (parity lsp-02).
//!
//! Owns long-lived language-server child processes (one `ServerInstance` per
//! server name), maps file extensions to server names, lazy-starts a server the
//! first time a file of its extension is touched, routes requests by extension,
//! and shuts everything down on exit. This is the substrate the rest of the LSP
//! phase hangs off (passive diagnostics injection lsp-01, doc-sync lsp-04,
//! lifecycle lsp-05, retry lsp-06, reverse requests lsp-09, etc.).
//!
//! Structural template: the MCP client's persistent stdio session map. Like
//! that map, the server map is mutated by reader threads (and the main thread),
//! so it is guarded by a mutex from day one.
//!
//! A transitional process-global singleton is exposed via `get`/`install`/
//! `installForTest`, mirroring `core/runtime.zig`. The agent runtime installs it
//! at setup (skipping `--bare`/headless modes, like the reference's
//! `isBareMode()` guard). When no manager is installed, callers fall back to the
//! stateless `tools/lsp.zig` path, so headless scripted LSP calls keep working.

const std = @import("std");
const rt = @import("zcode_runtime");
const std_io = @import("../std_io.zig");
const server_instance = @import("server_instance.zig");

const ServerInstance = server_instance.ServerInstance;

/// Map a file extension (including the leading dot) to an LSP `languageId`.
/// lsp-07 replaces this with the per-server `extensionToLanguage` table from
/// `config.zig`; until then it is an inline default so doc-sync notifications
/// carry a meaningful languageId. Unknown extensions fall back to "plaintext"
/// (matching the reference's default).
fn languageIdForExt(ext: []const u8) []const u8 {
    const table = [_]struct { ext: []const u8, lang: []const u8 }{
        .{ .ext = ".zig", .lang = "zig" },
        .{ .ext = ".py", .lang = "python" },
        .{ .ext = ".ts", .lang = "typescript" },
        .{ .ext = ".tsx", .lang = "typescriptreact" },
        .{ .ext = ".js", .lang = "javascript" },
        .{ .ext = ".jsx", .lang = "javascriptreact" },
        .{ .ext = ".go", .lang = "go" },
        .{ .ext = ".rs", .lang = "rust" },
        .{ .ext = ".c", .lang = "c" },
        .{ .ext = ".h", .lang = "c" },
        .{ .ext = ".cpp", .lang = "cpp" },
        .{ .ext = ".hpp", .lang = "cpp" },
        .{ .ext = ".java", .lang = "java" },
        .{ .ext = ".lua", .lang = "lua" },
    };
    for (table) |row| {
        if (std.mem.eql(u8, ext, row.ext)) return row.lang;
    }
    return "plaintext";
}

/// Build the `didOpen` params object. The file `text` and `uri` are emitted via
/// `std.json.Stringify` so a path with quotes / a file with control characters
/// is escaped correctly (the project footgun list warns against hand-rolled
/// JSON interpolation of untrusted text). Returns an owned slice.
fn buildDidOpenParams(
    allocator: std.mem.Allocator,
    uri: []const u8,
    language_id: []const u8,
    version: u32,
    content: []const u8,
) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, w);
    try w.writeAll(",\"languageId\":");
    try std.json.Stringify.value(language_id, .{}, w);
    try w.print(",\"version\":{d},\"text\":", .{version});
    try std.json.Stringify.value(content, .{}, w);
    try w.writeAll("}}");
    return buf.toOwnedSlice();
}

/// Build the `didChange` params for full-document sync: a single
/// `contentChanges` entry carrying the whole new text. Returns an owned slice.
fn buildDidChangeParams(
    allocator: std.mem.Allocator,
    uri: []const u8,
    content: []const u8,
) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    const w = buf.writer();
    try w.writeAll("{\"textDocument\":{\"uri\":");
    try std.json.Stringify.value(uri, .{}, w);
    try w.writeAll("},\"contentChanges\":[{\"text\":");
    try std.json.Stringify.value(content, .{}, w);
    try w.writeAll("}]}");
    return buf.toOwnedSlice();
}

/// Idempotent-init state of the manager, mirroring the reference's async-init
/// guard (`manager.ts:145-208`). lsp-10's `reinitialize` resets this to
/// `not_started`.
pub const InitState = enum { not_started, pending, success, failed };

/// One default extension -> server-name + argv mapping. lsp-07 promotes this
/// into a richer `core/lsp/config.zig` with per-server args/env/init options;
/// for lsp-02 the built-in table is inlined here so routing works zero-config.
pub const ServerDef = struct {
    /// File extension including the leading dot, e.g. ".zig".
    ext: []const u8,
    /// The server name / binary, e.g. "zls".
    name: []const u8,
};

/// Built-in default extension table, lifted from the hardcoded map in
/// `tools/lsp.zig:detectLanguageServer`. Promoted to `config.zig` by lsp-07.
pub const default_server_defs = [_]ServerDef{
    .{ .ext = ".zig", .name = "zls" },
    .{ .ext = ".py", .name = "pyright-langserver" },
    .{ .ext = ".ts", .name = "typescript-language-server" },
    .{ .ext = ".tsx", .name = "typescript-language-server" },
    .{ .ext = ".js", .name = "typescript-language-server" },
    .{ .ext = ".jsx", .name = "typescript-language-server" },
    .{ .ext = ".go", .name = "gopls" },
    .{ .ext = ".rs", .name = "rust-analyzer" },
    .{ .ext = ".c", .name = "clangd" },
    .{ .ext = ".h", .name = "clangd" },
    .{ .ext = ".cpp", .name = "clangd" },
    .{ .ext = ".hpp", .name = "clangd" },
    .{ .ext = ".java", .name = "jdtls" },
    .{ .ext = ".lua", .name = "lua-language-server" },
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// server-name -> live instance. Keys + instances owned by the manager.
    servers: std.StringHashMapUnmanaged(*ServerInstance) = .{},
    /// extension -> server-name. Keys + values owned by the manager.
    extension_map: std.StringHashMapUnmanaged([]const u8) = .{},
    /// file `file://` URI -> server-name the file is open on (lsp-04 doc-sync).
    /// Both key and value are owned by the manager. Tracks which files have had
    /// a `didOpen` sent so `changeFile`/`saveFile`/`closeFile` can route and so
    /// a `didChange` on a never-opened file is promoted to `didOpen`.
    opened_files: std.StringHashMapUnmanaged([]const u8) = .{},

    init_state: InitState = .not_started,

    /// Guards both maps (reader threads inside instances do not touch these
    /// maps, but sub-agent threads and the main turn loop both can).
    mutex: std.Io.Mutex = .init,

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Manager {
        const self = try allocator.create(Manager);
        self.* = .{ .allocator = allocator, .io = io };
        return self;
    }

    /// Build the extension map from the built-in defaults. lsp-07 will pass a
    /// merged (defaults + plugin) config in; for lsp-02 it reads the inlined
    /// `default_server_defs`. Idempotent: re-running clears and rebuilds.
    pub fn initialize(self: *Manager) !void {
        try self.initializeWith(&default_server_defs);
    }

    /// Build the extension map from an explicit set of server defs. This is the
    /// in-memory config-provider seam lsp-10's `reinitialize` test uses to change
    /// the configured servers between `initialize` and `reinitialize`. Idempotent:
    /// re-running clears and rebuilds.
    pub fn initializeWith(self: *Manager, defs: []const ServerDef) !void {
        self.lock();
        defer self.unlock();
        self.init_state = .pending;
        try self.buildExtensionMapLocked(defs);
        self.init_state = .success;
    }

    /// lsp-10: reinitialize on plugin refresh. Best-effort shutdown of running
    /// servers (so a `/reload-plugins` does not leak language-server children),
    /// reset `init_state` to `not_started`, then re-run `initialize` reading the
    /// fresh built-in defaults. Idempotent and safe with zero servers (the common
    /// case): with no servers started, this is just a config re-read. Shutdown
    /// errors are swallowed (the reference fire-and-forgets on reinit).
    pub fn reinitialize(self: *Manager) !void {
        try self.reinitializeWith(&default_server_defs);
    }

    /// `reinitialize` with an explicit config provider. Shuts the old server set
    /// down (joining reader threads via `shutdown`), resets `init_state`, and
    /// rebuilds the extension map from `defs`. The test uses this to prove a
    /// config that changed between calls is picked up after reinit.
    pub fn reinitializeWith(self: *Manager, defs: []const ServerDef) !void {
        // shutdown() takes the lock itself; call it outside our lock so reader
        // threads can be joined without holding the map mutex.
        self.shutdown();
        self.lock();
        self.init_state = .not_started;
        self.unlock();
        try self.initializeWith(defs);
    }

    fn buildExtensionMapLocked(self: *Manager, defs: []const ServerDef) !void {
        // Clear any prior map (reinit path).
        var it = self.extension_map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.extension_map.clearRetainingCapacity();

        for (defs) |def| {
            const ext_key = try self.allocator.dupe(u8, def.ext);
            errdefer self.allocator.free(ext_key);
            const name_val = try self.allocator.dupe(u8, def.name);
            errdefer self.allocator.free(name_val);
            // gop so a duplicate extension overwrites without leaking the key.
            const gop = try self.extension_map.getOrPut(self.allocator, ext_key);
            if (gop.found_existing) {
                self.allocator.free(ext_key);
                self.allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = name_val;
            } else {
                gop.value_ptr.* = name_val;
            }
        }
    }

    /// Resolve the server name for a file path by its extension, or null when no
    /// server is configured for that extension.
    pub fn serverNameForFile(self: *Manager, path: []const u8) ?[]const u8 {
        const ext = std.fs.path.extension(path);
        if (ext.len == 0) return null;
        self.lock();
        defer self.unlock();
        return self.extension_map.get(ext);
    }

    /// Look up (without starting) the live instance serving a file's extension,
    /// or null if no such instance has been started.
    pub fn getServerForFile(self: *Manager, path: []const u8) ?*ServerInstance {
        const name = self.serverNameForFile(path) orelse return null;
        self.lock();
        defer self.unlock();
        return self.servers.get(name);
    }

    /// Lazily start the server for a file's extension, returning the running
    /// instance. If the instance already exists and is running, it is reused
    /// (same child pid) rather than re-spawned. If it exists but is stopped /
    /// errored, it is restarted in place.
    pub fn ensureServerStarted(self: *Manager, path: []const u8) !*ServerInstance {
        const name = self.serverNameForFile(path) orelse return error.NoServerForExtension;

        self.lock();
        const existing = self.servers.get(name);
        self.unlock();

        if (existing) |inst| {
            if (inst.isRunning()) return inst; // reuse: proves persistence
            try inst.start(); // restart a stopped/errored instance in place
            return inst;
        }

        // Create + start a fresh instance, then register it.
        const argv = [_][]const u8{ name, "--stdio" };
        const inst = try ServerInstance.create(self.allocator, self.io, name, &argv);
        errdefer inst.destroy();
        try inst.start();

        self.lock();
        defer self.unlock();
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.servers.put(self.allocator, key, inst);
        return inst;
    }

    /// Route a request to the server for `path`'s extension, starting it if
    /// needed. Returns the response body owned by the caller.
    pub fn sendRequest(self: *Manager, path: []const u8, method: []const u8, params_json: []const u8) ![]u8 {
        const inst = try self.ensureServerStarted(path);
        return inst.sendRequest(method, params_json);
    }

    // --- lsp-04: document sync notifications -------------------------------
    //
    // Servers need `textDocument/did*` notifications to know about open
    // documents and to re-diagnose after an edit. Without them many servers
    // (TypeScript especially) never emit fresh diagnostics. Full-document sync
    // is used (the whole text on every change) -- the simplest scheme, and what
    // the reference sends.

    /// Build a `file://`-scheme URI for an absolute path. The doc-sync URIs and
    /// the diagnostic-publish URIs must agree, so both go through this one form
    /// (`file://{abs}`), matching the stateless `tools/lsp.zig` path and the
    /// registry's `uriToPath`.
    fn fileUri(self: *Manager, abs_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "file://{s}", .{abs_path});
    }

    /// True when a `didOpen` has been sent for `abs_path` and no `didClose` has
    /// followed. Reflects open/close transitions.
    pub fn isFileOpen(self: *Manager, abs_path: []const u8) bool {
        const uri = self.fileUri(abs_path) catch return false;
        defer self.allocator.free(uri);
        self.lock();
        defer self.unlock();
        return self.opened_files.contains(uri);
    }

    /// Send `textDocument/didOpen` for a file, lazily starting its server. A
    /// no-op when the file is already open on the same server. Records the file
    /// in `opened_files`.
    pub fn openFile(self: *Manager, abs_path: []const u8, content: []const u8) !void {
        const inst = try self.ensureServerStarted(abs_path);
        const server_name = self.serverNameForFile(abs_path) orelse return error.NoServerForExtension;

        const uri = try self.fileUri(abs_path);
        errdefer self.allocator.free(uri);

        // Already open on this server -> nothing to send.
        {
            self.lock();
            const existing = self.opened_files.get(uri);
            self.unlock();
            if (existing) |s| {
                if (std.mem.eql(u8, s, server_name)) {
                    self.allocator.free(uri);
                    return;
                }
            }
        }

        const lang = languageIdForExt(std.fs.path.extension(abs_path));
        const params = try buildDidOpenParams(self.allocator, uri, lang, 1, content);
        defer self.allocator.free(params);
        try inst.sendNotification("textDocument/didOpen", params);

        // Record (uri -> server-name) so later changes route + dedup correctly.
        self.lock();
        defer self.unlock();
        const uri_key = uri; // ownership moves into the map
        const name_val = try self.allocator.dupe(u8, server_name);
        errdefer self.allocator.free(name_val);
        const gop = try self.opened_files.getOrPut(self.allocator, uri_key);
        if (gop.found_existing) {
            // Different server for the same uri (rare): replace the value, free
            // the redundant duplicate key we just built.
            self.allocator.free(uri_key);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = name_val;
        } else {
            gop.value_ptr.* = name_val;
        }
    }

    /// Send `textDocument/didChange` (full-document sync) for an already-open
    /// file. If the file was never opened, this is promoted to `openFile` so a
    /// server that requires a prior `didOpen` is not confused.
    pub fn changeFile(self: *Manager, abs_path: []const u8, content: []const u8) !void {
        if (!self.isFileOpen(abs_path)) return self.openFile(abs_path, content);

        const inst = self.getServerForFile(abs_path) orelse return self.openFile(abs_path, content);
        const uri = try self.fileUri(abs_path);
        defer self.allocator.free(uri);
        const params = try buildDidChangeParams(self.allocator, uri, content);
        defer self.allocator.free(params);
        try inst.sendNotification("textDocument/didChange", params);
    }

    /// Send `textDocument/didSave` for an open file (no content). This is the
    /// notification that most reliably triggers a fresh diagnostics publish. A
    /// no-op when the file is not open (nothing to save).
    pub fn saveFile(self: *Manager, abs_path: []const u8) !void {
        if (!self.isFileOpen(abs_path)) return;
        const inst = self.getServerForFile(abs_path) orelse return;
        const uri = try self.fileUri(abs_path);
        defer self.allocator.free(uri);
        const params = try std.fmt.allocPrint(self.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{uri});
        defer self.allocator.free(params);
        try inst.sendNotification("textDocument/didSave", params);
    }

    /// Send `textDocument/didClose` for an open file and drop it from
    /// `opened_files`. A no-op when the file is not open.
    pub fn closeFile(self: *Manager, abs_path: []const u8) !void {
        if (!self.isFileOpen(abs_path)) return;
        const inst = self.getServerForFile(abs_path);
        const uri = try self.fileUri(abs_path);
        defer self.allocator.free(uri);

        if (inst) |i| {
            const params = try std.fmt.allocPrint(self.allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{uri});
            defer self.allocator.free(params);
            i.sendNotification("textDocument/didClose", params) catch {};
        }

        self.lock();
        defer self.unlock();
        if (self.opened_files.fetchRemove(uri)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
    }

    /// Snapshot of the live instances. The returned slice is owned by the
    /// caller; the `*ServerInstance` pointers remain owned by the manager.
    pub fn getAllServers(self: *Manager, allocator: std.mem.Allocator) ![]*ServerInstance {
        self.lock();
        defer self.unlock();
        var out = try allocator.alloc(*ServerInstance, self.servers.count());
        var i: usize = 0;
        var it = self.servers.valueIterator();
        while (it.next()) |v| {
            out[i] = v.*;
            i += 1;
        }
        return out;
    }

    /// Count of live (registered) instances. Convenience for tests/assertions.
    pub fn serverCount(self: *Manager) usize {
        self.lock();
        defer self.unlock();
        return self.servers.count();
    }

    /// True when at least one server is in the `running` state. Backs the LSP
    /// tool's "available" check.
    pub fn isConnected(self: *Manager) bool {
        self.lock();
        defer self.unlock();
        var it = self.servers.valueIterator();
        while (it.next()) |v| {
            if (v.*.isRunning()) return true;
        }
        return false;
    }

    /// Stop every server, free its instance, and clear the server map. Swallows
    /// per-server errors (reference swallows on exit). Idempotent: calling it
    /// again with an empty map is a no-op and leaves `serverCount() == 0`.
    pub fn shutdown(self: *Manager) void {
        self.lock();
        // Move the entries out under the lock, then stop/destroy outside the
        // lock so a slow `stop()` (joining a reader thread) does not hold the
        // map mutex.
        var instances: std.ArrayListUnmanaged(*ServerInstance) = .empty;
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = self.servers.iterator();
        while (it.next()) |e| {
            instances.append(self.allocator, e.value_ptr.*) catch {};
            keys.append(self.allocator, e.key_ptr.*) catch {};
        }
        self.servers.clearRetainingCapacity();

        // Open-file tracking is meaningless once the servers are gone; clear it
        // so a later openFile re-sends didOpen against a freshly-started server.
        var of = self.opened_files.iterator();
        while (of.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.opened_files.clearRetainingCapacity();
        self.unlock();

        for (instances.items) |inst| inst.destroy();
        for (keys.items) |k| self.allocator.free(k);
        instances.deinit(self.allocator);
        keys.deinit(self.allocator);
    }

    /// Tear down all servers and free the extension map + the manager itself.
    pub fn destroy(self: *Manager) void {
        self.shutdown();
        self.lock();
        var it = self.extension_map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.extension_map.deinit(self.allocator);
        self.servers.deinit(self.allocator);
        // shutdown() already freed + cleared opened_files entries; release the
        // map's backing storage.
        self.opened_files.deinit(self.allocator);
        self.unlock();
        self.allocator.destroy(self);
    }

    fn lock(self: *Manager) void {
        self.mutex.lock(self.io) catch {};
    }
    fn unlock(self: *Manager) void {
        self.mutex.unlock(self.io);
    }
};

// --- Transitional process-global singleton ---------------------------------

var instance: ?*Manager = null;

/// The installed manager, or null when none is installed (headless/`--bare`).
/// Callers guard with `if (manager.get()) |m| ...` and fall back to the
/// stateless `tools/lsp.zig` path when null.
pub fn get() ?*Manager {
    return instance;
}

/// Install a manager as the process singleton. Called from agent runtime setup
/// in non-bare modes. Replacing an existing one is the caller's responsibility
/// (lsp-10 reinit shuts the old one down first).
pub fn install(m: *Manager) void {
    instance = m;
}

/// Uninstall the singleton (does not destroy the manager).
pub fn uninstall() void {
    instance = null;
}

/// Test-only: build + install a manager backed by `rt.io`/`rt.gpa`, with the
/// extension map initialized. Returns the manager so the test can drive it and
/// `destroy` it.
pub fn installForTest() !*Manager {
    rt.installForTest();
    const m = try Manager.create(rt.gpa, rt.io);
    try m.initialize();
    install(m);
    return m;
}

// --- Tests ---

const testing = std.testing;
const test_helpers = @import("../test_helpers.zig");

/// Same stub-LSP shape as server_instance.zig, but spawnable via a stable name
/// the manager can map an extension to. We register a custom extension whose
/// "server name" is the python3 invocation written into the tmp dir, so the
/// manager spawns the stub instead of a real binary.
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

/// Build a manager whose `.stub` extension maps to a python3-invoked stub
/// server. Returns the manager and the abs script path (caller frees the path).
/// The manager's `ensureServerStarted` spawns `argv = {name, "--stdio"}`, so we
/// cannot use that path for python (it would run `python3-script --stdio`). For
/// the manager tests we instead drive `ServerInstance` lifecycle directly via
/// the manager's server map by pre-registering an instance. To keep the manager
/// API honest we override the spawn argv through a small test-only helper.
fn buildStub(tmp: *std.testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "stub.py", .data = stub_server_py });
    return test_helpers.tmpDirPath(testing.allocator, tmp, "stub.py");
}

/// Register a stub instance under `ext` in the manager's maps, spawning it via
/// the explicit python3 argv (bypassing the `name --stdio` convention which
/// only fits real binaries). Mirrors what `ensureServerStarted` would do, but
/// with a runnable argv for the test stub.
fn registerStub(m: *Manager, ext: []const u8, script: []const u8) !*ServerInstance {
    const argv = [_][]const u8{ "python3", script };
    const inst = try ServerInstance.create(m.allocator, m.io, "stub", &argv);
    errdefer inst.destroy();
    try inst.start();

    m.lock();
    defer m.unlock();
    const ext_key = try m.allocator.dupe(u8, ext);
    errdefer m.allocator.free(ext_key);
    const name_val = try m.allocator.dupe(u8, "stub");
    errdefer m.allocator.free(name_val);
    try m.extension_map.put(m.allocator, ext_key, name_val);
    const skey = try m.allocator.dupe(u8, "stub");
    errdefer m.allocator.free(skey);
    try m.servers.put(m.allocator, skey, inst);
    return inst;
}

test "Manager initialize builds the default extension map (.zig -> zls)" {
    rt.installForTest();
    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    try testing.expectEqualStrings("zls", m.serverNameForFile("/x/y/foo.zig").?);
    try testing.expectEqualStrings("gopls", m.serverNameForFile("/x/y/main.go").?);
    try testing.expect(m.serverNameForFile("/x/y/foo.unknownext") == null);
    try testing.expectEqual(InitState.success, m.init_state);
}

test "Manager isConnected is false before any server starts, true after" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    try testing.expect(!m.isConnected());

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    _ = try registerStub(m, ".stub", script);
    try testing.expect(m.isConnected());
}

test "Manager ensureServerStarted reuses the same child pid on a second call" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    // Pre-register a running stub for ".stub" (registerStub uses a runnable
    // python argv that the manager's `name --stdio` convention cannot express).
    _ = try registerStub(m, ".stub", script);

    const first = try m.ensureServerStarted("/proj/foo.stub");
    const pid1 = first.pid();
    try testing.expect(pid1 != null);

    // Second call for the same extension must reuse the SAME instance/pid,
    // proving persistence (not a fresh per-request spawn).
    const second = try m.ensureServerStarted("/proj/bar.stub");
    try testing.expectEqual(first, second);
    try testing.expectEqual(pid1, second.pid());
}

test "Manager sendRequest routes by extension and id-matches two methods" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    _ = try registerStub(m, ".stub", script);

    const r1 = try m.sendRequest("/proj/foo.stub", "textDocument/hover", "{}");
    defer testing.allocator.free(r1);
    const r2 = try m.sendRequest("/proj/foo.stub", "textDocument/definition", "{}");
    defer testing.allocator.free(r2);
    try testing.expect(std.mem.indexOf(u8, r1, "textDocument/hover") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "textDocument/definition") != null);
}

test "Manager shutdown leaves zero servers and is idempotent" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    _ = try registerStub(m, ".stub", script);
    try testing.expect(m.serverCount() >= 1);
    try testing.expect(m.isConnected());

    m.shutdown();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
    try testing.expect(!m.isConnected());

    // Second shutdown is a no-op.
    m.shutdown();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
}

test "Manager singleton install/get/uninstall" {
    rt.installForTest();
    uninstall();
    try testing.expect(get() == null);

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    install(m);
    try testing.expect(get() == m);

    uninstall();
    try testing.expect(get() == null);
}

// --- lsp-04: pure params-building tests (no server needed) -----------------

test "languageIdForExt maps known extensions and defaults to plaintext" {
    try testing.expectEqualStrings("zig", languageIdForExt(".zig"));
    try testing.expectEqualStrings("python", languageIdForExt(".py"));
    try testing.expectEqualStrings("typescript", languageIdForExt(".ts"));
    try testing.expectEqualStrings("plaintext", languageIdForExt(".unknownext"));
    try testing.expectEqualStrings("plaintext", languageIdForExt(""));
}

test "buildDidOpenParams escapes uri/text and carries languageId + version" {
    rt.installForTest();
    // Content with a quote, backslash and newline must be JSON-escaped, not
    // interpolated raw (the project footgun warns against hand-rolled JSON).
    const params = try buildDidOpenParams(testing.allocator, "file:///p/a.zig", "zig", 1, "a\"b\\c\n");
    defer testing.allocator.free(params);
    try testing.expect(std.mem.indexOf(u8, params, "\"languageId\":\"zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, params, "\"uri\":\"file:///p/a.zig\"") != null);
    // The escaped text must contain the escaped quote/backslash/newline.
    try testing.expect(std.mem.indexOf(u8, params, "a\\\"b\\\\c\\n") != null);
    // Result must be valid JSON.
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

test "buildDidChangeParams wraps full text in a single contentChanges entry" {
    rt.installForTest();
    const params = try buildDidChangeParams(testing.allocator, "file:///p/a.zig", "new text");
    defer testing.allocator.free(params);
    try testing.expect(std.mem.indexOf(u8, params, "\"contentChanges\":[{\"text\":\"new text\"}]") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
}

// --- lsp-04: document sync notification tests ------------------------------

/// Recording stub LSP server: same handshake/echo behavior as the plain stub,
/// but every received message's `method` is appended (one per line) to the
/// record file passed as argv[1]. Lets a doc-sync test assert the exact method
/// sequence the manager wrote to stdin (didOpen / didChange / didSave / ...).
const recording_stub_py =
    \\import json, sys
    \\record_path = sys.argv[1]
    \\def record(method):
    \\    with open(record_path, "a") as f:
    \\        f.write((method or "") + "\n")
    \\        f.flush()
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
    \\    record(method)
    \\    if method == "initialize":
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"capabilities":{}}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif mid is not None:
    \\        write_frame({"jsonrpc":"2.0","id":mid,"result":{"echoed":method}})
;

/// Register a recording stub under `ext`, writing received methods to `record`.
fn registerRecordingStub(m: *Manager, ext: []const u8, script: []const u8, record: []const u8) !*ServerInstance {
    const argv = [_][]const u8{ "python3", script, record };
    const inst = try ServerInstance.create(m.allocator, m.io, "stub", &argv);
    errdefer inst.destroy();
    try inst.start();

    m.lock();
    defer m.unlock();
    const ext_key = try m.allocator.dupe(u8, ext);
    errdefer m.allocator.free(ext_key);
    const name_val = try m.allocator.dupe(u8, "stub");
    errdefer m.allocator.free(name_val);
    try m.extension_map.put(m.allocator, ext_key, name_val);
    const skey = try m.allocator.dupe(u8, "stub");
    errdefer m.allocator.free(skey);
    try m.servers.put(m.allocator, skey, inst);
    return inst;
}

/// Read the record file back and return its newline-split contents (owned by
/// the caller). Polls briefly so the reader thread + stub have time to flush.
fn readRecord(tmp: *std.testing.TmpDir, sub: []const u8) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        const data = tmp.dir.readFileAlloc(rt.io, sub, testing.allocator, .limited(64 * 1024)) catch {
            clock_sleep();
            continue;
        };
        return data;
    }
    return testing.allocator.dupe(u8, "");
}

fn clock_sleep() void {
    const clk = @import("../clock.zig");
    clk.sleepNanos(3 * std.time.ns_per_ms);
}

/// Poll the record file until it contains `needle`, returning true on success.
fn waitForRecord(tmp: *std.testing.TmpDir, sub: []const u8, needle: []const u8) bool {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const data = tmp.dir.readFileAlloc(rt.io, sub, testing.allocator, .limited(64 * 1024)) catch {
            clock_sleep();
            continue;
        };
        defer testing.allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) return true;
        clock_sleep();
    }
    return false;
}

test "Manager openFile then changeFile sends didOpen then didChange" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rec.py", .data = recording_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rec.py");
    defer testing.allocator.free(script);
    // Pre-create an empty record file so tmpDirPath (realpath) resolves it and
    // the polling readers do not race the stub's first append.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "frames.log", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "frames.log");
    defer testing.allocator.free(record_abs);

    _ = try registerRecordingStub(m, ".stub", script, record_abs);

    try m.openFile("/proj/foo.stub", "const a = 1;\n");
    try m.changeFile("/proj/foo.stub", "const a = 2;\n");

    try testing.expect(waitForRecord(&tmp, "frames.log", "textDocument/didChange"));
    const data = try readRecord(&tmp, "frames.log");
    defer testing.allocator.free(data);

    // The recorded method sequence must contain didOpen before didChange.
    const open_idx = std.mem.indexOf(u8, data, "textDocument/didOpen");
    const change_idx = std.mem.indexOf(u8, data, "textDocument/didChange");
    try testing.expect(open_idx != null);
    try testing.expect(change_idx != null);
    try testing.expect(open_idx.? < change_idx.?);

    // Exactly one didOpen (the second open is deduped by opened_files).
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, data, "textDocument/didOpen"));
}

test "Manager changeFile on a never-opened file is promoted to didOpen" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rec.py", .data = recording_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rec.py");
    defer testing.allocator.free(script);
    // Pre-create an empty record file so tmpDirPath (realpath) resolves it and
    // the polling readers do not race the stub's first append.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "frames.log", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "frames.log");
    defer testing.allocator.free(record_abs);

    _ = try registerRecordingStub(m, ".stub", script, record_abs);

    // changeFile without a prior openFile must still register the document.
    try m.changeFile("/proj/bar.stub", "x\n");
    try testing.expect(m.isFileOpen("/proj/bar.stub"));
    try testing.expect(waitForRecord(&tmp, "frames.log", "textDocument/didOpen"));
}

test "Manager Write-equivalent (changeFile + saveFile) sends a didSave frame" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    // This mirrors what `tools/file.zig`'s notifyLspAfterWrite does on a
    // successful Write: changeFile (promoted to didOpen on first touch) then
    // saveFile. The doc-sync wiring in file.zig is covered separately for the
    // clearDeliveredForFile half (a pure registry test, no python needed); here
    // we prove the didSave frame actually reaches the server.
    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rec.py", .data = recording_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rec.py");
    defer testing.allocator.free(script);
    // Pre-create an empty record file so tmpDirPath (realpath) resolves it and
    // the polling readers do not race the stub's first append.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "frames.log", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "frames.log");
    defer testing.allocator.free(record_abs);

    _ = try registerRecordingStub(m, ".stub", script, record_abs);

    try m.changeFile("/proj/saved.stub", "v1\n");
    try m.saveFile("/proj/saved.stub");

    try testing.expect(waitForRecord(&tmp, "frames.log", "textDocument/didSave"));
}

test "Manager isFileOpen reflects open and close transitions" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "rec.py", .data = recording_stub_py });
    const script = try test_helpers.tmpDirPath(testing.allocator, &tmp, "rec.py");
    defer testing.allocator.free(script);
    // Pre-create an empty record file so tmpDirPath (realpath) resolves it and
    // the polling readers do not race the stub's first append.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "frames.log", .data = "" });
    const record_abs = try test_helpers.tmpDirPath(testing.allocator, &tmp, "frames.log");
    defer testing.allocator.free(record_abs);

    _ = try registerRecordingStub(m, ".stub", script, record_abs);

    try testing.expect(!m.isFileOpen("/proj/baz.stub"));
    try m.openFile("/proj/baz.stub", "y\n");
    try testing.expect(m.isFileOpen("/proj/baz.stub"));
    try m.closeFile("/proj/baz.stub");
    try testing.expect(!m.isFileOpen("/proj/baz.stub"));
    try testing.expect(waitForRecord(&tmp, "frames.log", "textDocument/didClose"));
}

// --- lsp-10: reinitialize on plugin refresh + clean shutdown ---------------

test "Manager destroy after starting a server leaves no child running" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    // Mirrors the agent_runtime deinit hook (`if (lsp_manager.get()) |m| m.shutdown()`):
    // a server started during the session must be torn down at teardown so no
    // language-server child is left running. destroy() calls shutdown() first.
    const m = try Manager.create(testing.allocator, rt.io);
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    _ = try registerStub(m, ".stub", script);
    try testing.expect(m.serverCount() >= 1);
    try testing.expect(m.isConnected());

    // destroy() (the deinit path) shuts every server down and frees the manager;
    // afterwards there is nothing left to count (we assert via shutdown() first
    // so we can read serverCount before the manager memory is freed).
    m.shutdown();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
    try testing.expect(!m.isConnected());
    m.destroy();
}

test "Manager reinitialize picks up a config that changed between calls" {
    rt.installForTest();

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();

    // First config: only ".aaa" is mapped.
    const cfg1 = [_]ServerDef{.{ .ext = ".aaa", .name = "aaa-server" }};
    try m.initializeWith(&cfg1);
    try testing.expectEqualStrings("aaa-server", m.serverNameForFile("/x/y/foo.aaa").?);
    try testing.expect(m.serverNameForFile("/x/y/foo.bbb") == null);

    // The config changes between calls (the in-memory provider seam). After
    // reinitialize the new extension mapping must be present and the old one
    // gone -- proving the manager re-read the fresh config.
    const cfg2 = [_]ServerDef{.{ .ext = ".bbb", .name = "bbb-server" }};
    try m.reinitializeWith(&cfg2);
    try testing.expectEqualStrings("bbb-server", m.serverNameForFile("/x/y/foo.bbb").?);
    try testing.expect(m.serverNameForFile("/x/y/foo.aaa") == null);
    try testing.expectEqual(InitState.success, m.init_state);
}

test "Manager reinitialize is idempotent and safe with zero servers" {
    rt.installForTest();

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    // The common case: no servers started. reinitialize must be a harmless
    // config re-read, repeatable, leaving the default map intact.
    try m.reinitialize();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
    try m.reinitialize();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
    try testing.expectEqualStrings("zls", m.serverNameForFile("/x/foo.zig").?);
    try testing.expectEqual(InitState.success, m.init_state);
}

test "Manager reinitialize shuts down a running server (no leaked child)" {
    rt.installForTest();
    if (@import("../env.zig").getenv("CI") != null) return error.SkipZigTest;

    const m = try Manager.create(testing.allocator, rt.io);
    defer m.destroy();
    try m.initialize();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try buildStub(&tmp);
    defer testing.allocator.free(script);

    _ = try registerStub(m, ".stub", script);
    try testing.expect(m.isConnected());

    // reinitialize tears the old server set down (joining its reader thread)
    // before rebuilding from the fresh defaults -- so a /reload-plugins does
    // not leak language-server children.
    try m.reinitialize();
    try testing.expectEqual(@as(usize, 0), m.serverCount());
    try testing.expect(!m.isConnected());
    // The default extension map is back (the ".stub" override is gone).
    try testing.expectEqualStrings("zls", m.serverNameForFile("/x/foo.zig").?);
    try testing.expect(m.serverNameForFile("/x/foo.stub") == null);
}
