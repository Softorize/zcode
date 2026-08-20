const std = @import("std");
const rng = @import("../core/rng.zig");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const args_mod = @import("arg_parse.zig");
const helpers = @import("helpers.zig");
const lsp_diag = @import("../core/lsp_diagnostics.zig");

const getArg = args_mod.getArg;

pub const ToolExecutionRequest = @import("tool_dispatch.zig").ToolExecutionRequest;

/// The list of supported LSP operations, used both for routing and for the
/// "unknown operation" error message so the two never drift apart.
const supported_operations =
    "goToDefinition, findReferences, hover, documentSymbol, goToImplementation, workspaceSymbol, prepareCallHierarchy, incomingCalls, outgoingCalls, diagnostics";

/// Session-scoped, lazily-initialized baseline store for the `diagnostics`
/// operation. `handleLsp` is called fresh per tool invocation, so the baseline
/// must outlive any single call; we keep one process-global store (the agent
/// runs one session per process). Matches the reference's per-session tracking;
/// no disk persistence.
var diag_store: ?lsp_diag.BaselineStore = null;

fn diagStore() *lsp_diag.BaselineStore {
    if (diag_store == null) {
        diag_store = lsp_diag.BaselineStore.init(rt.gpa);
    }
    return &diag_store.?;
}

/// Classifies an LSP operation by the inputs it needs, independent of any
/// live language server. Pure -- unit-testable without spawning a process.
pub const OperationKind = enum {
    /// Needs only filePath (no position, no query). e.g. documentSymbol.
    document,
    /// Needs filePath + line + character. e.g. goToDefinition, hover.
    position,
    /// Needs filePath + a free-text `query`. e.g. workspaceSymbol.
    query,
    /// Position-based, but runs the two-step prepare-then-call hierarchy
    /// JSON-RPC exchange. e.g. incomingCalls, outgoingCalls.
    call_hierarchy,
    /// Needs filePath; opens the file and waits for a publishDiagnostics
    /// notification rather than a request response. e.g. diagnostics.
    diagnostics,
    /// Not a recognized operation.
    unknown,
};

/// Pure routing decision: maps an operation name to the inputs it requires.
/// Returns `.unknown` for anything not in the supported set. This is the
/// single source of truth the dispatch loop in `handleLsp` follows, and it
/// is directly testable without a language server.
pub fn classifyOperation(operation: []const u8) OperationKind {
    if (std.mem.eql(u8, operation, "documentSymbol")) return .document;
    if (std.mem.eql(u8, operation, "goToDefinition")) return .position;
    if (std.mem.eql(u8, operation, "findReferences")) return .position;
    if (std.mem.eql(u8, operation, "hover")) return .position;
    if (std.mem.eql(u8, operation, "goToImplementation")) return .position;
    if (std.mem.eql(u8, operation, "prepareCallHierarchy")) return .position;
    if (std.mem.eql(u8, operation, "workspaceSymbol")) return .query;
    if (std.mem.eql(u8, operation, "incomingCalls")) return .call_hierarchy;
    if (std.mem.eql(u8, operation, "outgoingCalls")) return .call_hierarchy;
    if (std.mem.eql(u8, operation, "diagnostics")) return .diagnostics;
    return .unknown;
}

/// Handle LSP tool invocations. Delegates to the appropriate language
/// server based on file extension. Uses JSON-RPC over stdio to
/// communicate with the server.
pub fn handleLsp(allocator: std.mem.Allocator, req: ToolExecutionRequest) ![]u8 {
    const operation = getArg(req.args, "operation") orelse return allocator.dupe(u8, "error: missing 'operation' argument");
    const file_path = getArg(req.args, "filePath") orelse getArg(req.args, "file_path") orelse return allocator.dupe(u8, "error: missing 'filePath' argument");

    const kind = classifyOperation(operation);
    if (kind == .unknown) {
        return std.fmt.allocPrint(allocator, "error: unknown LSP operation '{s}'. Supported: {s}", .{ operation, supported_operations });
    }

    const abs = try helpers.normalizePath(allocator, req.cwd, file_path);
    defer allocator.free(abs);

    const server_cmd = detectLanguageServer(abs);
    if (server_cmd == null) {
        return std.fmt.allocPrint(allocator, "error: no language server found for '{s}'. Install zls (Zig), pyright (Python), typescript-language-server (TS/JS), gopls (Go), or rust-analyzer (Rust).", .{file_path});
    }

    switch (kind) {
        .document => return runDocumentSymbol(allocator, server_cmd.?, abs, req.cwd),
        .query => {
            const query = getArg(req.args, "query") orelse return allocator.dupe(u8, "error: missing 'query' argument for workspaceSymbol");
            return runWorkspaceSymbol(allocator, server_cmd.?, abs, req.cwd, query);
        },
        .diagnostics => {
            // mode is optional: "baseline" records the current diagnostics as
            // the comparison point; "check" (default) reports only newly-
            // introduced diagnostics since the recorded baseline.
            const mode = getArg(req.args, "mode") orelse "check";
            return runDiagnostics(allocator, server_cmd.?, abs, req.cwd, mode);
        },
        .position, .call_hierarchy => {},
        .unknown => unreachable,
    }

    // Operations that need line/character position.
    const line_str = getArg(req.args, "line") orelse return allocator.dupe(u8, "error: missing 'line' argument (1-based)");
    const char_str = getArg(req.args, "character") orelse return allocator.dupe(u8, "error: missing 'character' argument (1-based)");
    const line = (std.fmt.parseInt(u32, line_str, 10) catch 1);
    const character = (std.fmt.parseInt(u32, char_str, 10) catch 1);
    // Convert from 1-based (user) to 0-based (LSP protocol)
    const lsp_line = if (line > 0) line - 1 else 0;
    const lsp_char = if (character > 0) character - 1 else 0;

    if (std.mem.eql(u8, operation, "goToDefinition")) {
        return runPositionRequest(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "textDocument/definition");
    }
    if (std.mem.eql(u8, operation, "findReferences")) {
        return runPositionRequest(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "textDocument/references");
    }
    if (std.mem.eql(u8, operation, "hover")) {
        return runPositionRequest(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "textDocument/hover");
    }
    if (std.mem.eql(u8, operation, "goToImplementation")) {
        return runPositionRequest(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "textDocument/implementation");
    }
    if (std.mem.eql(u8, operation, "prepareCallHierarchy")) {
        return runPositionRequest(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "textDocument/prepareCallHierarchy");
    }
    if (std.mem.eql(u8, operation, "incomingCalls")) {
        return runCallHierarchy(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "callHierarchy/incomingCalls");
    }
    if (std.mem.eql(u8, operation, "outgoingCalls")) {
        return runCallHierarchy(allocator, server_cmd.?, abs, req.cwd, lsp_line, lsp_char, "callHierarchy/outgoingCalls");
    }

    return std.fmt.allocPrint(allocator, "error: unknown LSP operation '{s}'. Supported: {s}", .{ operation, supported_operations });
}

fn detectLanguageServer(file_path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".zig")) return "zls";
    if (std.mem.eql(u8, ext, ".py")) return "pyright-langserver";
    if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx"))
        return "typescript-language-server";
    if (std.mem.eql(u8, ext, ".go")) return "gopls";
    if (std.mem.eql(u8, ext, ".rs")) return "rust-analyzer";
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".hpp"))
        return "clangd";
    if (std.mem.eql(u8, ext, ".java")) return "jdtls";
    if (std.mem.eql(u8, ext, ".lua")) return "lua-language-server";
    return null;
}

/// Run a position-based LSP request (definition, references, hover, etc.)
/// by spawning the language server, initializing, opening the file,
/// sending the request, and extracting the result.
fn runPositionRequest(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    file_path: []const u8,
    cwd: []const u8,
    line: u32,
    character: u32,
    method: []const u8,
) ![]u8 {
    const file_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
    defer allocator.free(file_uri);

    // Build JSON-RPC messages: initialize + the actual request.
    // We pipe both messages to the server via stdin, then read stdout.
    var rpc_buf = std_io.StringBuilder.init(allocator);
    defer rpc_buf.deinit();
    const rpc_w = rpc_buf.writer();

    // Message 1: initialize
    var init_body_buf = std_io.StringBuilder.init(allocator);
    defer init_body_buf.deinit();
    try init_body_buf.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"processId\":{d},\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}",
        .{ std.c.getpid(), cwd },
    );
    try rpc_w.print("Content-Length: {d}\r\n\r\n", .{init_body_buf.items().len});
    try rpc_w.writeAll(init_body_buf.items());

    // Message 2: the actual request
    var req_body_buf = std_io.StringBuilder.init(allocator);
    defer req_body_buf.deinit();
    if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
        try req_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}}}}}}",
            .{ method, file_uri },
        );
    } else if (std.mem.eql(u8, method, "textDocument/references")) {
        try req_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"context\":{{\"includeDeclaration\":true}}}}}}",
            .{ method, file_uri, line, character },
        );
    } else {
        try req_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}",
            .{ method, file_uri, line, character },
        );
    }
    try rpc_w.print("Content-Length: {d}\r\n\r\n", .{req_body_buf.items().len});
    try rpc_w.writeAll(req_body_buf.items());

    // Spawn the LSP with stdin/stdout pipes so we can write JSON-RPC
    // directly to its stdin and read framed responses from stdout. No
    // shell or temp files in the path — the LSP request body may
    // contain user-controlled file paths.
    const rpc_text = rpc_buf.items();
    var child = std.process.spawn(rt.io, .{
        .argv = &.{ server_cmd, "--stdio" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to start '{s}': {s}. Install it for LSP support.", .{ server_cmd, @errorName(err) });
    };
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, rpc_text) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }

    const max_output = 512 * 1024;
    var stdout_buf = std_io.StringBuilder.init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |out_file| {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = out_file.readStreaming(rt.io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stdout_buf.items().len + n > max_output) break;
            stdout_buf.appendSlice(read_buf[0..n]) catch break;
        }
    }
    _ = child.wait(rt.io) catch {};
    const result_stdout = try stdout_buf.toOwnedSlice();
    defer allocator.free(result_stdout);

    if (result_stdout.len == 0) {
        return std.fmt.allocPrint(allocator, "LSP '{s}' returned no response.", .{server_cmd});
    }

    return extractLspResult(allocator, result_stdout, method);
}

fn runDocumentSymbol(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    file_path: []const u8,
    cwd: []const u8,
) ![]u8 {
    return runPositionRequest(allocator, server_cmd, file_path, cwd, 0, 0, "textDocument/documentSymbol");
}

/// Run the `diagnostics` operation. Diagnostics are delivered by the server as
/// a `textDocument/publishDiagnostics` NOTIFICATION (no `id`, no `result`)
/// emitted after `textDocument/didOpen`, NOT as a response to a request, so we
/// drive: initialize -> didOpen(file, contents) -> drain stdout until a
/// publishDiagnostics for this URI arrives (bounded by the read cap) -> parse.
///
/// `mode == "baseline"`: store the parsed diagnostics keyed by URI and report a
/// "baseline recorded" summary. `mode == "check"` (default): diff the current
/// diagnostics against the stored baseline and report only the new ones (with
/// no baseline, every current diagnostic is new). Baseline lives in the
/// session-scoped `diag_store`.
fn runDiagnostics(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    file_path: []const u8,
    cwd: []const u8,
    mode: []const u8,
) ![]u8 {
    const file_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
    defer allocator.free(file_uri);

    // Read the file contents to send in didOpen. If the read fails, send an
    // empty document so the server can still respond (it will just report
    // nothing useful); we do not hard-fail the tool on a read miss.
    const contents = std.Io.Dir.cwd().readFileAlloc(rt.io, file_path, allocator, .limited(2 * 1024 * 1024)) catch try allocator.dupe(u8, "");
    defer allocator.free(contents);

    const language_id = languageIdForServer(server_cmd);

    var rpc_buf = std_io.StringBuilder.init(allocator);
    defer rpc_buf.deinit();
    const rpc_w = rpc_buf.writer();

    // Message 1: initialize.
    var init_body_buf = std_io.StringBuilder.init(allocator);
    defer init_body_buf.deinit();
    try init_body_buf.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"processId\":{d},\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}",
        .{ std.c.getpid(), cwd },
    );
    try writeRpcFrame(rpc_w, init_body_buf.items());

    // Message 2: initialized notification (some servers withhold diagnostics
    // until this is sent).
    try writeRpcFrame(rpc_w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");

    // Message 3: didOpen with the file text (JSON-escaped).
    var text_buf = std_io.StringBuilder.init(allocator);
    defer text_buf.deinit();
    try std.json.Stringify.value(contents, .{}, text_buf.writer());

    var open_body_buf = std_io.StringBuilder.init(allocator);
    defer open_body_buf.deinit();
    try open_body_buf.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\",\"version\":1,\"text\":{s}}}}}}}",
        .{ file_uri, language_id, text_buf.items() },
    );
    try writeRpcFrame(rpc_w, open_body_buf.items());

    const raw = runLspExchange(allocator, server_cmd, rpc_buf.items()) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to start '{s}': {s}. Install it for LSP support.", .{ server_cmd, @errorName(err) });
    };
    defer allocator.free(raw);

    const current = try lsp_diag.parsePublishDiagnostics(allocator, raw, file_uri);
    defer lsp_diag.freeDiagnostics(allocator, current);

    if (std.mem.eql(u8, mode, "baseline")) {
        try diagStore().setBaseline(file_uri, current);
        return std.fmt.allocPrint(
            allocator,
            "LSP diagnostics baseline recorded for {s}: {d} diagnostic(s).",
            .{ file_path, current.len },
        );
    }

    // Default: check mode. Report only diagnostics new since the baseline.
    const store = diagStore();
    const new_diags = try store.newSince(allocator, file_uri, current);
    defer lsp_diag.freeDiagnostics(allocator, new_diags);

    return formatDiagnosticsReport(allocator, file_path, current, new_diags, store.hasBaseline(file_uri));
}

/// Format the check-mode report: a header noting whether a baseline existed,
/// then a line per newly-introduced diagnostic.
fn formatDiagnosticsReport(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    current: []const lsp_diag.Diagnostic,
    new_diags: []const lsp_diag.Diagnostic,
    had_baseline: bool,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    const w = out.writer();

    if (had_baseline) {
        try w.print(
            "LSP diagnostics for {s}: {d} new since baseline ({d} total).\n",
            .{ file_path, new_diags.len, current.len },
        );
    } else {
        try w.print(
            "LSP diagnostics for {s}: no baseline recorded; reporting all {d} diagnostic(s).\n",
            .{ file_path, current.len },
        );
    }

    if (new_diags.len == 0) {
        try w.writeAll("(none)\n");
    } else {
        for (new_diags) |d| {
            // line is 0-based internally; present 1-based to the user.
            try w.print("  line {d} [{s}]: {s}\n", .{ d.line + 1, d.severityLabel(), d.message });
        }
    }

    return out.toOwnedSlice();
}

/// Map a language-server command to the LSP `languageId` string used in
/// didOpen. The server is keyed off the file extension already; this is the
/// inverse mapping needed for the didOpen payload.
fn languageIdForServer(server_cmd: []const u8) []const u8 {
    if (std.mem.eql(u8, server_cmd, "zls")) return "zig";
    if (std.mem.eql(u8, server_cmd, "pyright-langserver")) return "python";
    if (std.mem.eql(u8, server_cmd, "typescript-language-server")) return "typescript";
    if (std.mem.eql(u8, server_cmd, "gopls")) return "go";
    if (std.mem.eql(u8, server_cmd, "rust-analyzer")) return "rust";
    if (std.mem.eql(u8, server_cmd, "clangd")) return "cpp";
    if (std.mem.eql(u8, server_cmd, "jdtls")) return "java";
    if (std.mem.eql(u8, server_cmd, "lua-language-server")) return "lua";
    return "plaintext";
}

/// Append a framed JSON-RPC message (Content-Length header + body) to `w`.
fn writeRpcFrame(w: anytype, body: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
}

/// Run `workspace/symbol`, a query-based (not position-based) request. The
/// server is given a free-text `query` and returns matching symbols across
/// the whole workspace. Unlike position requests there is no `textDocument`
/// or `position` in the params, only `{ "query": <q> }`.
fn runWorkspaceSymbol(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    file_path: []const u8,
    cwd: []const u8,
    query: []const u8,
) ![]u8 {
    _ = file_path; // workspace/symbol is not scoped to a single document

    const method = "workspace/symbol";

    var rpc_buf = std_io.StringBuilder.init(allocator);
    defer rpc_buf.deinit();
    const rpc_w = rpc_buf.writer();

    // Message 1: initialize
    var init_body_buf = std_io.StringBuilder.init(allocator);
    defer init_body_buf.deinit();
    try init_body_buf.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"processId\":{d},\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}",
        .{ std.c.getpid(), cwd },
    );
    try writeRpcFrame(rpc_w, init_body_buf.items());

    // Message 2: workspace/symbol with the JSON-escaped query.
    var query_buf = std_io.StringBuilder.init(allocator);
    defer query_buf.deinit();
    try std.json.Stringify.value(query, .{}, query_buf.writer());

    var req_body_buf = std_io.StringBuilder.init(allocator);
    defer req_body_buf.deinit();
    try req_body_buf.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"{s}\",\"params\":{{\"query\":{s}}}}}",
        .{ method, query_buf.items() },
    );
    try writeRpcFrame(rpc_w, req_body_buf.items());

    const raw = runLspExchange(allocator, server_cmd, rpc_buf.items()) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to start '{s}': {s}. Install it for LSP support.", .{ server_cmd, @errorName(err) });
    };
    defer allocator.free(raw);
    if (raw.len == 0) {
        return std.fmt.allocPrint(allocator, "LSP '{s}' returned no response.", .{server_cmd});
    }
    return extractLspResult(allocator, raw, method);
}

/// Run a two-step call-hierarchy request (`callHierarchy/incomingCalls` or
/// `callHierarchy/outgoingCalls`). Call hierarchy is inherently two-step in
/// LSP: first `textDocument/prepareCallHierarchy` returns one or more
/// CallHierarchyItem objects, then the incoming/outgoing request is sent with
/// the chosen item. We therefore drive an interactive write-read-write-read
/// exchange with the server rather than the fire-and-forget single write the
/// position requests use. Deviation note: zls and several other servers have
/// limited call-hierarchy support, so we degrade gracefully with a clear
/// message when no prepared item or no result is returned.
fn runCallHierarchy(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    file_path: []const u8,
    cwd: []const u8,
    line: u32,
    character: u32,
    method: []const u8,
) ![]u8 {
    const file_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
    defer allocator.free(file_uri);

    // Spawn the server with stdin/stdout pipes. We keep stdin open across the
    // prepare step so we can compose the second request from the prepared item.
    var child = std.process.spawn(rt.io, .{
        .argv = &.{ server_cmd, "--stdio" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        return std.fmt.allocPrint(allocator, "error: failed to start '{s}': {s}. Install it for LSP support.", .{ server_cmd, @errorName(err) });
    };

    // Frame 1+2: initialize + prepareCallHierarchy. Written together so the
    // server can answer the prepare while we begin reading.
    {
        var rpc_buf = std_io.StringBuilder.init(allocator);
        defer rpc_buf.deinit();
        const rpc_w = rpc_buf.writer();

        var init_body_buf = std_io.StringBuilder.init(allocator);
        defer init_body_buf.deinit();
        try init_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"processId\":{d},\"rootUri\":\"file://{s}\",\"capabilities\":{{}}}}}}",
            .{ std.c.getpid(), cwd },
        );
        try writeRpcFrame(rpc_w, init_body_buf.items());

        var prep_body_buf = std_io.StringBuilder.init(allocator);
        defer prep_body_buf.deinit();
        try prep_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"textDocument/prepareCallHierarchy\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}}}",
            .{ file_uri, line, character },
        );
        try writeRpcFrame(rpc_w, prep_body_buf.items());

        if (child.stdin) |stdin_file| {
            stdin_file.writeStreamingAll(rt.io, rpc_buf.items()) catch {};
        }
    }

    // Read until we have the prepare (id 2) response, then extract the item.
    const prepare_out = readLspUntilLimit(allocator, &child) catch try allocator.dupe(u8, "");
    defer allocator.free(prepare_out);

    const item_json = extractResultArrayFirst(allocator, prepare_out, 2) catch null;
    defer if (item_json) |ij| allocator.free(ij);

    if (item_json == null) {
        if (child.stdin) |stdin_file| {
            stdin_file.close(rt.io);
            child.stdin = null;
        }
        _ = child.wait(rt.io) catch {};
        return std.fmt.allocPrint(allocator, "LSP {s}: server returned no call-hierarchy item for this position (the server may not support call hierarchy here).", .{method});
    }

    // Frame 3: the incoming/outgoing request carrying the prepared item.
    {
        var rpc_buf = std_io.StringBuilder.init(allocator);
        defer rpc_buf.deinit();
        var call_body_buf = std_io.StringBuilder.init(allocator);
        defer call_body_buf.deinit();
        try call_body_buf.writer().print(
            "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"{s}\",\"params\":{{\"item\":{s}}}}}",
            .{ method, item_json.? },
        );
        try writeRpcFrame(rpc_buf.writer(), call_body_buf.items());
        if (child.stdin) |stdin_file| {
            stdin_file.writeStreamingAll(rt.io, rpc_buf.items()) catch {};
            stdin_file.close(rt.io);
            child.stdin = null;
        }
    }

    const call_out = readLspUntilLimit(allocator, &child) catch try allocator.dupe(u8, "");
    defer allocator.free(call_out);
    _ = child.wait(rt.io) catch {};

    const combined = if (call_out.len > 0) call_out else prepare_out;
    if (combined.len == 0) {
        return std.fmt.allocPrint(allocator, "LSP '{s}' returned no response.", .{server_cmd});
    }
    return extractLspResult(allocator, combined, method);
}

/// Spawn the language server, write the already-framed `rpc_text` to its
/// stdin, close stdin, drain stdout up to the read cap, and reap the child.
/// Used by the single-write requests (workspace/symbol). Returns owned bytes.
fn runLspExchange(allocator: std.mem.Allocator, server_cmd: []const u8, rpc_text: []const u8) ![]u8 {
    var child = try std.process.spawn(rt.io, .{
        .argv = &.{ server_cmd, "--stdio" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    if (child.stdin) |stdin_file| {
        stdin_file.writeStreamingAll(rt.io, rpc_text) catch {};
        stdin_file.close(rt.io);
        child.stdin = null;
    }
    const out = readLspUntilLimit(allocator, &child) catch try allocator.dupe(u8, "");
    _ = child.wait(rt.io) catch {};
    return out;
}

/// Drain the child's stdout up to the 512KiB read cap. Returns owned bytes
/// (possibly empty). Tracks offset implicitly via streaming reads.
fn readLspUntilLimit(allocator: std.mem.Allocator, child: *std.process.Child) ![]u8 {
    const max_output = 512 * 1024;
    var stdout_buf = std_io.StringBuilder.init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |out_file| {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = out_file.readStreaming(rt.io, &.{&read_buf}) catch break;
            if (n == 0) break;
            if (stdout_buf.items().len + n > max_output) break;
            stdout_buf.appendSlice(read_buf[0..n]) catch break;
        }
    }
    return stdout_buf.toOwnedSlice();
}

/// Scan framed JSON-RPC output for the response with the given `id` and, if
/// its `result` is a non-empty array, return the first element re-serialized
/// as owned JSON. Returns null if no such response/result/element is found.
/// Used to pluck the prepared CallHierarchyItem out of the prepare response.
fn extractResultArrayFirst(allocator: std.mem.Allocator, raw: []const u8, id: i64) !?[]u8 {
    var search = raw;
    while (std.mem.indexOf(u8, search, "{\"jsonrpc\"")) |idx| {
        const start = search[idx..];
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (std.json.parseFromSlice(std.json.Value, arena.allocator(), start, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                const obj = parsed.value.object;
                const id_match = if (obj.get("id")) |idv|
                    (idv == .integer and idv.integer == id)
                else
                    false;
                if (id_match) {
                    if (obj.get("result")) |res| {
                        if (res == .array and res.array.items.len > 0) {
                            // Re-serialize the first item as owned JSON.
                            var out = std_io.StringBuilder.init(allocator);
                            errdefer out.deinit();
                            try std.json.Stringify.value(res.array.items[0], .{}, out.writer());
                            return try out.toOwnedSlice();
                        }
                    }
                }
            }
        } else |_| {}
        if (idx + 1 < search.len) {
            search = search[idx + 1 ..];
        } else break;
    }
    return null;
}

// buildLspScript removed -- replaced by direct stdin pipe in
// runPositionRequest (the shell script approach was broken: the
// second printf had no stdin connection to the server).

fn extractLspResult(allocator: std.mem.Allocator, raw: []const u8, method: []const u8) ![]u8 {
    // Find JSON-RPC responses in the output (may have Content-Length headers)
    var best_result: ?[]const u8 = null;
    var search = raw;
    while (std.mem.indexOf(u8, search, "{\"jsonrpc\"")) |idx| {
        const start = search[idx..];
        // Try to parse as JSON
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (std.json.parseFromSlice(std.json.Value, arena.allocator(), start, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("result")) |_| {
                    best_result = start;
                }
            }
        } else |_| {}
        if (idx + 1 < search.len) {
            search = search[idx + 1 ..];
        } else break;
    }

    if (best_result) |result| {
        const take = @min(result.len, 50_000);
        return std.fmt.allocPrint(allocator, "LSP {s} result:\n{s}", .{ method, result[0..take] });
    }

    return std.fmt.allocPrint(allocator, "LSP {s}: no result found in server response", .{method});
}

// --- Tests ---

const testing = std.testing;

test "classifyOperation routes all supported operations" {
    // documentSymbol needs only filePath.
    try testing.expectEqual(OperationKind.document, classifyOperation("documentSymbol"));
    // Position-based.
    try testing.expectEqual(OperationKind.position, classifyOperation("goToDefinition"));
    try testing.expectEqual(OperationKind.position, classifyOperation("findReferences"));
    try testing.expectEqual(OperationKind.position, classifyOperation("hover"));
    try testing.expectEqual(OperationKind.position, classifyOperation("goToImplementation"));
    try testing.expectEqual(OperationKind.position, classifyOperation("prepareCallHierarchy"));
    // Query-based.
    try testing.expectEqual(OperationKind.query, classifyOperation("workspaceSymbol"));
    // Two-step call hierarchy.
    try testing.expectEqual(OperationKind.call_hierarchy, classifyOperation("incomingCalls"));
    try testing.expectEqual(OperationKind.call_hierarchy, classifyOperation("outgoingCalls"));
    // Diagnostics (publishDiagnostics notification, baseline/check).
    try testing.expectEqual(OperationKind.diagnostics, classifyOperation("diagnostics"));
}

test "classifyOperation returns unknown for unrecognized op" {
    try testing.expectEqual(OperationKind.unknown, classifyOperation("notAnOp"));
    try testing.expectEqual(OperationKind.unknown, classifyOperation(""));
}

test "handleLsp unknown operation error lists all supported operations" {
    const args = "\"operation\":\"bogusOp\",\"filePath\":\"foo.zig\"";
    const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = args, .cwd = "/tmp" });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "error: unknown LSP operation 'bogusOp'"));
    // Every supported operation must be named.
    const ops = [_][]const u8{
        "goToDefinition",       "findReferences",     "hover",
        "documentSymbol",       "goToImplementation", "workspaceSymbol",
        "prepareCallHierarchy", "incomingCalls",      "outgoingCalls",
        "diagnostics",
    };
    for (ops) |op| {
        try testing.expect(std.mem.indexOf(u8, out, op) != null);
    }
}

test "handleLsp diagnostics without filePath returns a clear error" {
    // The missing-filePath check runs before any server is spawned, so this is
    // network/server-free.
    const args = "\"operation\":\"diagnostics\"";
    const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = args, .cwd = "/tmp" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "missing 'filePath'") != null);
}

test "handleLsp diagnostics routes (no unknown-operation error)" {
    // Use an extension with no installed language server so we exercise the
    // routing decision without spawning anything. The result must be the
    // "no language server" branch, NOT the unknown-operation branch.
    const args = "\"operation\":\"diagnostics\",\"filePath\":\"foo.unknownext\"";
    const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = args, .cwd = "/tmp" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "unknown LSP operation") == null);
    try testing.expect(std.mem.indexOf(u8, out, "no language server") != null);
}

test "handleLsp workspaceSymbol without query returns a clear error" {
    // A .zig path resolves to the zls server name without spawning anything,
    // so the missing-query branch is reached before any process is launched.
    const args = "\"operation\":\"workspaceSymbol\",\"filePath\":\"foo.zig\"";
    const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = args, .cwd = "/tmp" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "missing 'query'") != null);
}

test "handleLsp missing operation and missing filePath errors" {
    {
        const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = "", .cwd = "/tmp" });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "missing 'operation'") != null);
    }
    {
        const args = "\"operation\":\"hover\"";
        const out = try handleLsp(testing.allocator, .{ .name = "LSP", .args = args, .cwd = "/tmp" });
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "missing 'filePath'") != null);
    }
}

test "extractResultArrayFirst plucks first array element of matching id" {
    const raw =
        "Content-Length: 60\r\n\r\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[{\"name\":\"foo\"},{\"name\":\"bar\"}]}";
    const got = try extractResultArrayFirst(testing.allocator, raw, 2);
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "\"foo\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.?, "bar") == null);
}

test "extractResultArrayFirst returns null for empty or absent result" {
    // Wrong id.
    {
        const raw = "{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":[{\"name\":\"x\"}]}";
        const got = try extractResultArrayFirst(testing.allocator, raw, 2);
        defer if (got) |g| testing.allocator.free(g);
        try testing.expect(got == null);
    }
    // Empty array.
    {
        const raw = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":[]}";
        const got = try extractResultArrayFirst(testing.allocator, raw, 2);
        defer if (got) |g| testing.allocator.free(g);
        try testing.expect(got == null);
    }
    // Null result.
    {
        const raw = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":null}";
        const got = try extractResultArrayFirst(testing.allocator, raw, 2);
        defer if (got) |g| testing.allocator.free(g);
        try testing.expect(got == null);
    }
}
