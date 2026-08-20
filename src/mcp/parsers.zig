const std = @import("std");
const std_io = @import("../core/std_io.zig");
const client = @import("client.zig");
const parse_helpers = @import("../core/parse_helpers.zig");
const blob_spill = @import("../core/mcp_blob_spill.zig");
const output_limits = @import("../core/mcp_output_limits.zig");

const ToolInfo = client.ToolInfo;
const ResourceInfo = client.ResourceInfo;
const ResourceTemplateInfo = client.ResourceTemplateInfo;
const ResourceContent = client.ResourceContent;
const PromptInfo = client.PromptInfo;
const PromptArgument = client.PromptArgument;
const PromptMessage = client.PromptMessage;
const PromptResult = client.PromptResult;
const CompletionResult = client.CompletionResult;

// -- Public helpers (also used by client.zig) --

pub fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn getInteger(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |n| n,
        else => null,
    };
}

pub fn jsonValueAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var buf = std_io.StringBuilder.init(allocator);
    defer buf.deinit();
    try buf.writer().print("{f}", .{std.json.fmt(value, .{})});
    return buf.toOwnedSlice();
}

// -- JSON-RPC error code extraction + session-expiry detection (mcp-13) --

/// Extract the integer `code` from a JSON-RPC error envelope. Looks for an
/// `error` object at the top level and, failing that, under `result` (some
/// gateways nest the error). Returns null when the body is not parseable, has
/// no error object, or the error carries no integer code. Pure: parses with the
/// caller's allocator and frees before returning so callers need not own the
/// parsed tree. Reference: client.ts:200-206 keys on the `"code":-32001`
/// substring; we parse the code field rather than string-matching so a
/// formatting variant (`"code": -32001`) is handled identically.
pub fn parseRpcErrorCode(allocator: std.mem.Allocator, response_json: []const u8) ?i64 {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    if (errorCodeFromObject(root)) |code| return code;
    if (root.get("result")) |result| {
        if (result == .object) {
            if (errorCodeFromObject(result.object)) |code| return code;
        }
    }
    return null;
}

/// Pull `error.code` (integer) out of an object map, or null when there is no
/// error object or no integer code on it.
fn errorCodeFromObject(obj: std.json.ObjectMap) ?i64 {
    const err = obj.get("error") orelse return null;
    if (err != .object) return null;
    return getInteger(err.object, "code");
}

/// True when an HTTP response signals an expired/unknown MCP session: HTTP 404
/// AND JSON-RPC error code -32001 (session-not-found). Keyed on 404 to match the
/// reference (client.ts:200-206 + the 404 re-init at client.ts:1911-1922); a
/// -32001 under any other status (e.g. 200) is NOT treated as session expiry.
pub fn isSessionExpired(http_status: u16, rpc_code: ?i64) bool {
    if (http_status != 404) return false;
    const code = rpc_code orelse return false;
    return code == -32001;
}

// -- Private helpers (only used by parser functions within this file) --

fn responseArrayField(root: std.json.Value, field_name: []const u8) ?std.json.Array {
    if (root == .object) {
        if (root.object.get(field_name)) |value| {
            if (value == .array) return value.array;
        }
    }
    if (root == .object) {
        if (root.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get(field_name)) |value| {
                    if (value == .array) return value.array;
                }
            }
        }
    }
    return null;
}

fn responseObjectField(root: std.json.Value, field_name: []const u8) ?std.json.ObjectMap {
    if (root != .object) return null;
    if (root.object.get(field_name)) |value| {
        if (value == .object) return value.object;
    }
    return null;
}

/// Context threaded through the content transform so MCP result blocks can be
/// turned into the right textual representation (mcp-08). Holds the server name
/// for provenance prefixes and, optionally, a spill directory so binary blobs
/// can be written to disk instead of inlined. When `spill_dir` is null the
/// transform degrades gracefully to a short marker without touching the
/// filesystem (keeps the prompt-message flattener pure).
pub const TransformContext = struct {
    /// Originating MCP server name, used in `[Resource from <server> at <uri>]`
    /// provenance prefixes. Empty string when unknown.
    server_name: []const u8 = "",
    /// Absolute directory blobs spill into. Null disables disk spill.
    spill_dir: ?[]const u8 = null,

    /// The pure context: no server name, no spill. Used by callers that only
    /// want a flat string and never write to disk.
    pub const none: TransformContext = .{};
};

fn flattenContentValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return flattenContentValueCtx(allocator, value, TransformContext.none);
}

/// Transform one MCP content value into a textual block. Handles the block
/// shapes the reference's `transformResultContent` covers
/// (client.ts:2478-2591): text passthrough, resource-with-text inlining (with
/// a provenance prefix), resource-with-blob spill, resource_link formatting,
/// and image/audio handling. Arrays are flattened newline-joined.
pub fn flattenContentValueCtx(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    ctx: TransformContext,
) ![]u8 {
    return switch (value) {
        .string => |text| allocator.dupe(u8, text),
        .array => |items| blk: {
            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();
            for (items.items) |item| {
                const piece = flattenContentValueCtx(allocator, item, ctx) catch continue;
                defer allocator.free(piece);
                if (piece.len == 0) continue;
                if (out.items().len > 0) try out.append('\n');
                try out.appendSlice(piece);
            }
            break :blk out.toOwnedSlice();
        },
        .object => |obj| blk: {
            const block_type = getString(obj, "type") orelse "";

            // resource_link: a pointer to a resource the model can fetch.
            if (std.mem.eql(u8, block_type, "resource_link")) {
                break :blk formatResourceLink(allocator, obj);
            }

            // resource: inline text, or spill a blob.
            if (obj.get("resource")) |resource_val| {
                if (resource_val == .object) {
                    break :blk transformResource(allocator, resource_val.object, ctx);
                }
            }

            // image / audio top-level blocks carrying base64 `data`.
            if (std.mem.eql(u8, block_type, "image") or std.mem.eql(u8, block_type, "audio")) {
                if (transformMedia(allocator, block_type, obj, ctx)) |text| {
                    break :blk text;
                } else |_| {}
            }

            // Plain text block.
            if (obj.get("text")) |text_val| {
                if (text_val == .string) break :blk allocator.dupe(u8, text_val.string);
            }

            const object_value: std.json.Value = .{ .object = obj };
            break :blk jsonValueAlloc(allocator, object_value);
        },
        else => allocator.dupe(u8, ""),
    };
}

/// Format a `resource_link` block as
/// `[Resource link: <name>] <uri> (<description>)` (description omitted when
/// absent). Mirrors the reference's resource_link branch.
fn formatResourceLink(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]u8 {
    const uri = getString(obj, "uri") orelse "";
    const name = getString(obj, "name") orelse uri;
    const description = getString(obj, "description") orelse "";
    if (description.len > 0) {
        return std.fmt.allocPrint(allocator, "[Resource link: {s}] {s} ({s})", .{ name, uri, description });
    }
    return std.fmt.allocPrint(allocator, "[Resource link: {s}] {s}", .{ name, uri });
}

/// Transform an embedded `resource` object. When it carries `text`, inline it
/// behind a `[Resource from <server> at <uri>]` provenance prefix (this is the
/// inlining that was a bare `resource: <uri> <mime>` stub before mcp-08). When
/// it carries a `blob`, spill the decoded bytes to disk (if a spill dir is
/// configured) and emit a saved-path marker, or a short marker otherwise.
fn transformResource(
    allocator: std.mem.Allocator,
    resource: std.json.ObjectMap,
    ctx: TransformContext,
) ![]u8 {
    const uri = getString(resource, "uri") orelse "resource";
    const mime = getString(resource, "mimeType") orelse getString(resource, "mime_type") orelse "";

    if (getString(resource, "text")) |text| {
        return std.fmt.allocPrint(
            allocator,
            "[Resource from {s} at {s}] {s}",
            .{ ctx.server_name, uri, text },
        );
    }

    if (getString(resource, "blob")) |blob_b64| {
        return spillOrMark(allocator, blob_b64, mime, uri, ctx);
    }

    return std.fmt.allocPrint(allocator, "[Resource from {s} at {s}] ({s})", .{ ctx.server_name, uri, mime });
}

/// Transform a top-level `image` / `audio` content block. Images are noted with
/// a short marker (zcode has no image codec, so we do not resize - see
/// deferred notes). Audio is spilled like any other binary blob.
fn transformMedia(
    allocator: std.mem.Allocator,
    block_type: []const u8,
    obj: std.json.ObjectMap,
    ctx: TransformContext,
) ![]u8 {
    const data_b64 = getString(obj, "data") orelse return error.NoData;
    const mime = getString(obj, "mimeType") orelse getString(obj, "mime_type") orelse "";

    if (std.mem.eql(u8, block_type, "image")) {
        // Emit a compact marker rather than inlining the base64 (which would
        // blow the context). True inline-image support is handled at the
        // typed-block layer; here we keep the textual fallback honest.
        return std.fmt.allocPrint(allocator, "[Image content ({s}, {d} base64 bytes)]", .{ mime, data_b64.len });
    }

    // audio: spill the decoded bytes.
    return spillOrMark(allocator, data_b64, mime, "audio", ctx);
}

/// Spill a base64 blob to the context's spill dir and return a saved-path
/// marker. If no spill dir is configured (or decode/write fails), fall back to
/// a short marker so the model still learns a blob was present.
fn spillOrMark(
    allocator: std.mem.Allocator,
    blob_b64: []const u8,
    mime: []const u8,
    label: []const u8,
    ctx: TransformContext,
) ![]u8 {
    const dir = ctx.spill_dir orelse {
        return std.fmt.allocPrint(allocator, "[Binary content ({s}, {d} base64 bytes) at {s}]", .{ mime, blob_b64.len, label });
    };

    const decoded = blob_spill.decodeBase64(allocator, blob_b64) catch {
        return std.fmt.allocPrint(allocator, "[Binary content ({s}) at {s}: could not decode]", .{ mime, label });
    };
    defer allocator.free(decoded);

    var result = blob_spill.persistBlobToDir(allocator, dir, decoded, mime, ctx.server_name) catch {
        return std.fmt.allocPrint(allocator, "[Binary content ({s}, {d} bytes) at {s}: spill failed]", .{ mime, decoded.len, label });
    };
    defer result.deinit(allocator);

    return blob_spill.savedMessage(allocator, result.filepath, result.size, mime);
}

/// Infer a compact, human-readable schema string from a JSON value
/// (client.ts:2644-2660). Objects render as `{key: type, ...}` with at most the
/// first 10 keys (a `, ...` suffix marks truncation); arrays render as
/// `[elemtype]` from the first element (or `[]` when empty); scalars render as
/// `string` / `number` / `boolean` / `null`. Recursion stops at `depth == 0`,
/// where objects collapse to `{...}` and arrays to `[...]`. Caller frees.
pub fn inferCompactSchema(allocator: std.mem.Allocator, value: std.json.Value, depth: u8) ![]u8 {
    return switch (value) {
        .null => allocator.dupe(u8, "null"),
        .bool => allocator.dupe(u8, "boolean"),
        .integer, .float, .number_string => allocator.dupe(u8, "number"),
        .string => allocator.dupe(u8, "string"),
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk allocator.dupe(u8, "[]");
            // Arrays are transparent containers: they describe their element
            // type without consuming a nesting level, so `items: [{id}]` shows
            // the element object at the same depth budget as the array itself.
            const elem = try inferCompactSchema(allocator, arr.items[0], depth);
            defer allocator.free(elem);
            break :blk std.fmt.allocPrint(allocator, "[{s}]", .{elem});
        },
        .object => |obj| blk: {
            if (depth == 0) break :blk allocator.dupe(u8, "{...}");
            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();
            try out.append('{');
            var it = obj.iterator();
            var count: usize = 0;
            const max_keys: usize = 10;
            while (it.next()) |entry| {
                if (count >= max_keys) {
                    try out.appendSlice(", ...");
                    break;
                }
                if (count > 0) try out.appendSlice(", ");
                const field_schema = try inferCompactSchema(allocator, entry.value_ptr.*, depth - 1);
                defer allocator.free(field_schema);
                try out.appendSlice(entry.key_ptr.*);
                try out.appendSlice(": ");
                try out.appendSlice(field_schema);
                count += 1;
            }
            try out.append('}');
            break :blk out.toOwnedSlice();
        },
    };
}

// -- InitializeInfo (private type, exposed only through this module) --

pub const InitializeInfo = struct {
    protocol_version: []u8,
    server_name: []u8,
    server_version: []u8,
    /// Optional instructions block the MCP server sends at handshake
    /// to tell the model how to use its tools. Matches the MCP spec's
    /// InitializeResult.instructions field. Lives on a session-per-
    /// session basis and is injected into the system prompt via the
    /// mcp-server-instructions reminder. null when the server does
    /// not send this field (common for simple servers that rely on
    /// tool descriptions alone).
    instructions: ?[]u8,

    pub fn deinit(self: *InitializeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.protocol_version);
        allocator.free(self.server_name);
        allocator.free(self.server_version);
        if (self.instructions) |text| allocator.free(text);
    }
};

pub fn parseInitializeInfo(allocator: std.mem.Allocator, response_json: []const u8) !InitializeInfo {
    var parsed = try parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json);
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;

    const protocol_version = if (result.object.get("protocolVersion")) |value|
        switch (value) {
            .string => |text| text,
            else => "unknown",
        }
    else
        "unknown";

    const server_name = if (result.object.get("serverInfo")) |server_info|
        switch (server_info) {
            .object => getString(server_info.object, "name") orelse "unknown",
            else => "unknown",
        }
    else
        "unknown";

    const server_version = if (result.object.get("serverInfo")) |server_info|
        switch (server_info) {
            .object => getString(server_info.object, "version") orelse "unknown",
            else => "unknown",
        }
    else
        "unknown";

    // Pull the optional "instructions" field. MCP spec allows servers
    // to send a markdown string here telling the model how to use
    // their tools. Duped so the caller owns it independent of the
    // parsed JSON lifetime.
    var instructions: ?[]u8 = null;
    if (result.object.get("instructions")) |value| {
        if (value == .string and value.string.len > 0) {
            instructions = try allocator.dupe(u8, value.string);
        }
    }

    return .{
        .protocol_version = try allocator.dupe(u8, protocol_version),
        .server_name = try allocator.dupe(u8, server_name),
        .server_version = try allocator.dupe(u8, server_version),
        .instructions = instructions,
    };
}

// -- Public parser functions --

pub fn parseToolsResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]ToolInfo {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.alloc(ToolInfo, 0);
    };
    defer parsed.deinit();

    const tools_val = if (parsed.value == .array)
        parsed.value
    else if (parsed.value == .object and parsed.value.object.get("tools") != null)
        parsed.value.object.get("tools").?
    else if (parsed.value == .object and parsed.value.object.get("result") != null and parsed.value.object.get("result").? == .object and parsed.value.object.get("result").?.object.get("tools") != null)
        parsed.value.object.get("result").?.object.get("tools").?
    else
        return allocator.alloc(ToolInfo, 0);

    if (tools_val != .array) return allocator.alloc(ToolInfo, 0);

    var out = std.array_list.Managed(ToolInfo).init(allocator);
    errdefer {
        for (out.items) |t| {
            allocator.free(t.name);
            allocator.free(t.description);
            allocator.free(t.input_schema);
        }
        out.deinit();
    }

    for (tools_val.array.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;
        const desc = getString(item.object, "description") orelse "";

        try out.ensureUnusedCapacity(1);
        const schema_text = if (item.object.get("inputSchema")) |schema|
            try jsonValueAlloc(allocator, schema)
        else if (item.object.get("input_schema")) |schema|
            try jsonValueAlloc(allocator, schema)
        else
            try allocator.dupe(u8, "{\"type\":\"object\",\"properties\":{\"payload\":{\"type\":\"string\"}}}");
        errdefer allocator.free(schema_text);
        const dup_name = try allocator.dupe(u8, name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, desc);
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .input_schema = schema_text,
        });
    }

    return out.toOwnedSlice();
}

pub fn parseResourcesResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]ResourceInfo {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.alloc(ResourceInfo, 0);
    };
    defer parsed.deinit();

    const resources_val = responseArrayField(parsed.value, "resources") orelse return allocator.alloc(ResourceInfo, 0);

    var out = std.array_list.Managed(ResourceInfo).init(allocator);
    errdefer {
        for (out.items) |r| {
            allocator.free(r.uri);
            allocator.free(r.name);
            allocator.free(r.description);
            allocator.free(r.mime_type);
        }
        out.deinit();
    }

    for (resources_val.items) |item| {
        if (item != .object) continue;
        const uri = getString(item.object, "uri") orelse continue;
        try out.ensureUnusedCapacity(1);
        const dup_uri = try allocator.dupe(u8, uri);
        errdefer allocator.free(dup_uri);
        const dup_name = try allocator.dupe(u8, getString(item.object, "name") orelse uri);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, getString(item.object, "description") orelse "");
        errdefer allocator.free(dup_description);
        const dup_mime = try allocator.dupe(u8, getString(item.object, "mimeType") orelse getString(item.object, "mime_type") orelse "");
        out.appendAssumeCapacity(.{
            .uri = dup_uri,
            .name = dup_name,
            .description = dup_description,
            .mime_type = dup_mime,
        });
    }

    return out.toOwnedSlice();
}

pub fn parseResourceTemplatesResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]ResourceTemplateInfo {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.alloc(ResourceTemplateInfo, 0);
    };
    defer parsed.deinit();

    const templates_val = responseArrayField(parsed.value, "resourceTemplates") orelse
        responseArrayField(parsed.value, "resource_templates") orelse
        return allocator.alloc(ResourceTemplateInfo, 0);

    var out = std.array_list.Managed(ResourceTemplateInfo).init(allocator);
    errdefer {
        for (out.items) |t| {
            allocator.free(t.uri_template);
            allocator.free(t.name);
            allocator.free(t.description);
            allocator.free(t.mime_type);
        }
        out.deinit();
    }

    for (templates_val.items) |item| {
        if (item != .object) continue;
        const uri_template = getString(item.object, "uriTemplate") orelse getString(item.object, "uri_template") orelse continue;
        try out.ensureUnusedCapacity(1);
        const dup_template = try allocator.dupe(u8, uri_template);
        errdefer allocator.free(dup_template);
        const dup_name = try allocator.dupe(u8, getString(item.object, "name") orelse uri_template);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, getString(item.object, "description") orelse "");
        errdefer allocator.free(dup_description);
        const dup_mime = try allocator.dupe(u8, getString(item.object, "mimeType") orelse getString(item.object, "mime_type") orelse "");
        out.appendAssumeCapacity(.{
            .uri_template = dup_template,
            .name = dup_name,
            .description = dup_description,
            .mime_type = dup_mime,
        });
    }

    return out.toOwnedSlice();
}

pub fn parseResourceReadResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]ResourceContent {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.alloc(ResourceContent, 0);
    };
    defer parsed.deinit();

    const contents_val = responseArrayField(parsed.value, "contents") orelse return allocator.alloc(ResourceContent, 0);

    var out = std.array_list.Managed(ResourceContent).init(allocator);
    errdefer {
        for (out.items) |c| {
            allocator.free(c.uri);
            allocator.free(c.mime_type);
            if (c.text) |t| allocator.free(t);
            if (c.blob_base64) |b| allocator.free(b);
        }
        out.deinit();
    }

    for (contents_val.items) |item| {
        if (item != .object) continue;
        try out.ensureUnusedCapacity(1);
        const dup_uri = try allocator.dupe(u8, getString(item.object, "uri") orelse "");
        errdefer allocator.free(dup_uri);
        const dup_mime = try allocator.dupe(u8, getString(item.object, "mimeType") orelse getString(item.object, "mime_type") orelse "");
        errdefer allocator.free(dup_mime);
        const dup_text: ?[]u8 = if (item.object.get("text")) |value| switch (value) {
            .string => |text| try allocator.dupe(u8, text),
            else => null,
        } else null;
        errdefer if (dup_text) |t| allocator.free(t);
        const dup_blob: ?[]u8 = if (item.object.get("blob")) |value| switch (value) {
            .string => |blob| try allocator.dupe(u8, blob),
            else => null,
        } else null;
        out.appendAssumeCapacity(.{
            .uri = dup_uri,
            .mime_type = dup_mime,
            .text = dup_text,
            .blob_base64 = dup_blob,
        });
    }

    return out.toOwnedSlice();
}

pub fn parsePromptsResponse(allocator: std.mem.Allocator, response_json: []const u8) ![]PromptInfo {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.alloc(PromptInfo, 0);
    };
    defer parsed.deinit();

    const prompts_val = responseArrayField(parsed.value, "prompts") orelse return allocator.alloc(PromptInfo, 0);

    var out = std.array_list.Managed(PromptInfo).init(allocator);
    errdefer {
        for (out.items) |p| {
            allocator.free(p.name);
            allocator.free(p.description);
            for (p.arguments) |a| {
                allocator.free(a.name);
                allocator.free(a.description);
            }
            allocator.free(p.arguments);
        }
        out.deinit();
    }

    for (prompts_val.items) |item| {
        if (item != .object) continue;
        const name = getString(item.object, "name") orelse continue;

        var args = std.array_list.Managed(PromptArgument).init(allocator);
        // Iteration-scoped cleanup: on either normal exit (args drained
        // by toOwnedSlice) or error exit (args still has items), walk
        // items and free. Using errdefer (not defer) because on success
        // toOwnedSlice transfers the backing, so the success path walks
        // zero items.
        errdefer {
            for (args.items) |arg| {
                allocator.free(arg.name);
                allocator.free(arg.description);
            }
            args.deinit();
        }

        if (item.object.get("arguments")) |arguments_val| {
            if (arguments_val == .array) {
                for (arguments_val.array.items) |arg_item| {
                    if (arg_item != .object) continue;
                    const arg_name = getString(arg_item.object, "name") orelse continue;
                    const required = if (arg_item.object.get("required")) |required_val|
                        switch (required_val) {
                            .bool => |value| value,
                            else => false,
                        }
                    else
                        false;

                    try args.ensureUnusedCapacity(1);
                    const dup_arg_name = try allocator.dupe(u8, arg_name);
                    errdefer allocator.free(dup_arg_name);
                    const dup_arg_description = try allocator.dupe(u8, getString(arg_item.object, "description") orelse "");
                    args.appendAssumeCapacity(.{
                        .name = dup_arg_name,
                        .description = dup_arg_description,
                        .required = required,
                    });
                }
            }
        }

        try out.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, getString(item.object, "description") orelse "");
        errdefer allocator.free(dup_description);
        // toOwnedSlice drains args so the iteration's args errdefer walks
        // zero items at block end (no double-free). The slice ownership
        // transfers into `owned_args`; it's freed by the outer out
        // errdefer once the appendAssumeCapacity below commits.
        const owned_args = try args.toOwnedSlice();
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .arguments = owned_args,
        });
    }

    return out.toOwnedSlice();
}

pub fn parsePromptResponse(allocator: std.mem.Allocator, response_json: []const u8) !PromptResult {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return error.InvalidResponse;
    defer parsed.deinit();

    const result_obj = responseObjectField(parsed.value, "result") orelse if (parsed.value == .object) parsed.value.object else return error.InvalidResponse;
    const description = getString(result_obj, "description") orelse "";
    const messages_val = result_obj.get("messages") orelse return error.InvalidResponse;
    if (messages_val != .array) return error.InvalidResponse;

    var messages = std.array_list.Managed(PromptMessage).init(allocator);
    // errdefer (not defer) so on success we walk zero items after
    // toOwnedSlice drains the list. Previously `defer` was correct only
    // because the struct init at the return site happened to leak the
    // description dupe on toOwnedSlice OOM -- now that we stage the
    // description dupe ourselves, errdefer is the right primitive.
    errdefer {
        for (messages.items) |message| {
            allocator.free(message.role);
            allocator.free(message.content);
        }
        messages.deinit();
    }

    for (messages_val.array.items) |item| {
        if (item != .object) continue;
        const role = getString(item.object, "role") orelse "user";
        const content = if (item.object.get("content")) |content_val|
            flattenContentValue(allocator, content_val) catch try allocator.dupe(u8, "")
        else
            try allocator.dupe(u8, "");
        errdefer allocator.free(content);
        try messages.ensureUnusedCapacity(1);
        const dup_role = try allocator.dupe(u8, role);
        messages.appendAssumeCapacity(.{
            .role = dup_role,
            .content = content,
        });
    }

    const dup_description = try allocator.dupe(u8, description);
    errdefer allocator.free(dup_description);
    const owned_messages = try messages.toOwnedSlice();
    return .{
        .description = dup_description,
        .messages = owned_messages,
    };
}

pub fn parseCompletionResponse(allocator: std.mem.Allocator, response_json: []const u8) !CompletionResult {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return CompletionResult{
        .values = try allocator.alloc([]u8, 0),
    };
    defer parsed.deinit();

    const result_obj = responseObjectField(parsed.value, "result") orelse if (parsed.value == .object) parsed.value.object else return CompletionResult{
        .values = try allocator.alloc([]u8, 0),
    };
    const completion_obj = if (result_obj.get("completion")) |value|
        switch (value) {
            .object => value.object,
            else => return CompletionResult{ .values = try allocator.alloc([]u8, 0) },
        }
    else
        return CompletionResult{ .values = try allocator.alloc([]u8, 0) };

    var values = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (values.items) |item| allocator.free(item);
        values.deinit();
    }

    if (completion_obj.get("values")) |values_val| {
        if (values_val == .array) {
            for (values_val.array.items) |item| {
                switch (item) {
                    .string => |text| {
                        const duped = try allocator.dupe(u8, text);
                        values.append(duped) catch |err| {
                            allocator.free(duped);
                            return err;
                        };
                    },
                    .object => |obj| {
                        if (getString(obj, "value")) |value| {
                            const duped = try allocator.dupe(u8, value);
                            values.append(duped) catch |err| {
                                allocator.free(duped);
                                return err;
                            };
                        }
                    },
                    else => {},
                }
            }
        }
    }

    const total = if (completion_obj.get("total")) |total_val| switch (total_val) {
        .integer => |value| std.math.cast(usize, value),
        else => null,
    } else null;
    const has_more = if (completion_obj.get("hasMore")) |has_more_val|
        switch (has_more_val) {
            .bool => |value| value,
            else => false,
        }
    else if (completion_obj.get("has_more")) |has_more_val|
        switch (has_more_val) {
            .bool => |value| value,
            else => false,
        }
    else
        false;

    return .{
        .values = try values.toOwnedSlice(),
        .total = total,
        .has_more = has_more,
    };
}

pub fn parseNextCursorAlloc(allocator: std.mem.Allocator, response_json: []const u8) !?[]u8 {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return null;
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("nextCursor")) |value| {
            if (value == .string) return @as(?[]u8, try allocator.dupe(u8, value.string));
        }
        if (parsed.value.object.get("next_cursor")) |value| {
            if (value == .string) return @as(?[]u8, try allocator.dupe(u8, value.string));
        }
        if (parsed.value.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get("nextCursor")) |value| {
                    if (value == .string) return @as(?[]u8, try allocator.dupe(u8, value.string));
                }
                if (result.object.get("next_cursor")) |value| {
                    if (value == .string) return @as(?[]u8, try allocator.dupe(u8, value.string));
                }
            }
        }
    }

    return null;
}

pub fn extractToolCallResultText(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    return extractToolCallResultTextCtx(allocator, response_json, TransformContext.none);
}

/// Like `extractToolCallResultText` but threads a `TransformContext` so result
/// blocks can carry provenance prefixes and spill binary blobs to disk
/// (mcp-08). Also wires the 100KB `shouldSpill` cap: an oversized textual
/// result is written to the spill dir and replaced by a pointer block so a huge
/// tool result does not blow the model context. The plain `extractToolCallResultText`
/// adapter keeps existing string-only callers source-compatible.
pub fn extractToolCallResultTextCtx(
    allocator: std.mem.Allocator,
    response_json: []const u8,
    ctx: TransformContext,
) ![]u8 {
    // If the server returned bytes we cannot parse as JSON at all, treat
    // the full body as plain text and let the caller's unicode sanitizer
    // see it. Non-JSON bodies are rare but not protocol-invalid for some
    // proxies. We trim to keep the model from choking on trailing noise.
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        const trimmed = std.mem.trim(u8, response_json, " \t\r\n");
        if (trimmed.len == 0) return allocator.dupe(u8, "");
        return maybeSpillResult(allocator, try allocator.dupe(u8, trimmed), ctx);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return allocator.dupe(u8, "MCP: server returned a non-object response.");
    }

    const obj = parsed.value.object;
    if (obj.get("error")) |err_val| {
        if (err_val == .object) {
            if (err_val.object.get("message")) |msg| {
                if (msg == .string) return std.fmt.allocPrint(allocator, "MCP error: {s}", .{msg.string});
            }
        }
    }

    const result = obj.get("result") orelse {
        return allocator.dupe(u8, "MCP: response missing \"result\" field.");
    };

    // Some servers (older implementations, HTTP gateways) return a bare
    // string as the whole result. Pass it through unchanged.
    if (result == .string) return maybeSpillResult(allocator, try allocator.dupe(u8, result.string), ctx);

    if (result != .object) {
        return allocator.dupe(u8, "MCP: server returned a non-structured result.");
    }

    if (result.object.get("content")) |content| {
        if (content == .array) {
            var out = std_io.StringBuilder.init(allocator);
            defer out.deinit();

            // structuredContent: surface a compact inferred schema as a leading
            // line so the model gets a type hint, then the JSON body. Mirrors
            // transformMCPResult (client.ts:2662-2706).
            if (result.object.get("structuredContent")) |structured| {
                const schema = inferCompactSchema(allocator, structured, 2) catch null;
                defer if (schema) |s| allocator.free(s);
                const body = try jsonValueAlloc(allocator, structured);
                defer allocator.free(body);
                if (schema) |s| {
                    try out.writer().print("[schema: {s}]\n", .{s});
                }
                try out.appendSlice(body);
            }

            for (content.array.items) |item| {
                if (item != .object) continue;
                if (flattenContentValueCtx(allocator, item, ctx)) |piece| {
                    defer allocator.free(piece);
                    if (piece.len == 0) continue;
                    if (out.items().len > 0) try out.append('\n');
                    try out.appendSlice(piece);
                } else |_| {}
            }

            if (out.items().len > 0) return maybeSpillResult(allocator, try out.toOwnedSlice(), ctx);
        }
    }

    // structuredContent without a content array: emit schema + JSON.
    if (result.object.get("structuredContent")) |structured| {
        var out = std_io.StringBuilder.init(allocator);
        defer out.deinit();
        const schema = inferCompactSchema(allocator, structured, 2) catch null;
        defer if (schema) |s| allocator.free(s);
        const body = try jsonValueAlloc(allocator, structured);
        defer allocator.free(body);
        if (schema) |s| try out.writer().print("[schema: {s}]\n", .{s});
        try out.appendSlice(body);
        return maybeSpillResult(allocator, try out.toOwnedSlice(), ctx);
    }

    // Fallbacks for servers that skip the standard content-array shape:
    //   - `result.text`   -> flat string
    //   - `result.output` -> flat string (common in custom gateways)
    //   - `result.toolResult` / `result.tool_result` -> arbitrary JSON
    if (result.object.get("text")) |value| {
        if (value == .string) return maybeSpillResult(allocator, try allocator.dupe(u8, value.string), ctx);
    }
    if (result.object.get("output")) |value| {
        if (value == .string) return maybeSpillResult(allocator, try allocator.dupe(u8, value.string), ctx);
    }
    for ([_][]const u8{ "toolResult", "tool_result" }) |key| {
        if (result.object.get(key)) |value| {
            if (value == .string) return maybeSpillResult(allocator, try allocator.dupe(u8, value.string), ctx);
            return maybeSpillResult(allocator, try jsonValueAlloc(allocator, value), ctx);
        }
    }

    // Last resort: format the result object compactly. Never dump the
    // whole raw envelope (jsonrpc headers, ids, batch metadata) back
    // into the model context.
    const compact: std.json.Value = .{ .object = result.object };
    return maybeSpillResult(allocator, try jsonValueAlloc(allocator, compact), ctx);
}

/// Wire the 100KB inline cap (`shouldSpill`): if `text` exceeds the cap and a
/// spill dir is configured, write it to disk and return a small pointer block
/// instead. Otherwise return `text` unchanged. Takes ownership of `text`.
fn maybeSpillResult(allocator: std.mem.Allocator, text: []u8, ctx: TransformContext) ![]u8 {
    if (!output_limits.shouldSpill(text.len)) return text;
    const dir = ctx.spill_dir orelse return text;

    var result = blob_spill.persistBlobToDir(allocator, dir, text, "text/plain", ctx.server_name) catch return text;
    defer result.deinit(allocator);
    defer allocator.free(text);
    return blob_spill.savedMessage(allocator, result.filepath, result.size, "text/plain");
}

const testing = std.testing;
test "getString extracts string" {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"k\":\"v\"}", .{});
    defer p.deinit();
    try testing.expectEqualStrings("v", getString(p.value.object, "k").?);
}
test "getInteger extracts int" {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"n\":42}", .{});
    defer p.deinit();
    try testing.expectEqual(@as(?i64, 42), getInteger(p.value.object, "n"));
}
test "parseNextCursorAlloc null when missing" {
    try testing.expect((try parseNextCursorAlloc(testing.allocator, "{\"result\":{}}")) == null);
}

test "parseInitializeInfo populates instructions field when server sent one" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\  "protocolVersion":"2024-11-05",
        \\  "serverInfo":{"name":"kali-tools","version":"1.2.3"},
        \\  "instructions":"Use nmap_scan for port scanning. Always pass a target."
        \\}}
    ;
    var info = try parseInitializeInfo(testing.allocator, raw);
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("2024-11-05", info.protocol_version);
    try testing.expectEqualStrings("kali-tools", info.server_name);
    try testing.expectEqualStrings("1.2.3", info.server_version);
    try testing.expect(info.instructions != null);
    try testing.expectEqualStrings(
        "Use nmap_scan for port scanning. Always pass a target.",
        info.instructions.?,
    );
}

test "parseInitializeInfo leaves instructions null when absent" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\  "protocolVersion":"2024-11-05",
        \\  "serverInfo":{"name":"simple","version":"0.1"}
        \\}}
    ;
    var info = try parseInitializeInfo(testing.allocator, raw);
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), info.instructions);
}

test "extractToolCallResultText flattens the standard content-array shape" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"hello"}]}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "extractToolCallResultText returns bare-string result unchanged" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":"already flat"}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("already flat", out);
}

test "extractToolCallResultText uses result.text fallback" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"text":"custom gateway output"}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("custom gateway output", out);
}

test "extractToolCallResultText never leaks rpc envelope for unknown shape" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"status":"ok","rows":42}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    // Must surface the result object, never the outer envelope keys.
    try testing.expect(std.mem.indexOf(u8, out, "jsonrpc") == null);
    try testing.expect(std.mem.indexOf(u8, out, "status") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rows") != null);
}

test "extractToolCallResultText reports a missing result field" {
    const raw =
        \\{"jsonrpc":"2.0","id":1}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "missing") != null);
}

test "extractToolCallResultText propagates server error messages" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("MCP error: method not found", out);
}

test "parseInitializeInfo ignores empty instructions string" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{
        \\  "protocolVersion":"2024-11-05",
        \\  "serverInfo":{"name":"x","version":"y"},
        \\  "instructions":""
        \\}}
    ;
    var info = try parseInitializeInfo(testing.allocator, raw);
    defer info.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), info.instructions);
}

// -- mcp-08 content transform tests --

const test_helpers = @import("../core/test_helpers.zig");

test "transform inlines a resource with text behind a provenance prefix" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[
        \\  {"type":"resource","resource":{"uri":"file:///doc.md","mimeType":"text/markdown","text":"hello world"}}
        \\]}}
    ;
    const out = try extractToolCallResultTextCtx(testing.allocator, raw, .{ .server_name = "docs-server" });
    defer testing.allocator.free(out);
    // The text is inlined (was a bare `resource: <uri>` stub before mcp-08)...
    try testing.expect(std.mem.indexOf(u8, out, "hello world") != null);
    // ...behind the `[Resource from <server> at <uri>]` provenance prefix.
    try testing.expect(std.mem.indexOf(u8, out, "[Resource from docs-server at file:///doc.md]") != null);
}

test "transform formats a resource_link block" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[
        \\  {"type":"resource_link","name":"Spec","uri":"https://x/spec","description":"the spec"}
        \\]}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[Resource link: Spec] https://x/spec (the spec)", out);
}

test "transform formats a resource_link without a description" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[
        \\  {"type":"resource_link","name":"Spec","uri":"https://x/spec"}
        \\]}}
    ;
    const out = try extractToolCallResultText(testing.allocator, raw);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[Resource link: Spec] https://x/spec", out);
}

test "inferCompactSchema renders nested objects and arrays" {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"title\":\"x\",\"items\":[{\"id\":1}]}", .{});
    defer p.deinit();
    const schema = try inferCompactSchema(testing.allocator, p.value, 2);
    defer testing.allocator.free(schema);
    try testing.expectEqualStrings("{title: string, items: [{id: number}]}", schema);
}

test "inferCompactSchema truncates objects past 10 keys with a comma-ellipsis" {
    const json =
        \\{"a":1,"b":1,"c":1,"d":1,"e":1,"f":1,"g":1,"h":1,"i":1,"j":1,"k":1,"l":1}
    ;
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer p.deinit();
    const schema = try inferCompactSchema(testing.allocator, p.value, 2);
    defer testing.allocator.free(schema);
    try testing.expect(std.mem.endsWith(u8, schema, ", ...}"));
}

test "inferCompactSchema collapses at the depth cutoff" {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"deep\":{\"x\":1}}", .{});
    defer p.deinit();
    // depth 1: top object expands, nested object collapses to {...}.
    const schema = try inferCompactSchema(testing.allocator, p.value, 1);
    defer testing.allocator.free(schema);
    try testing.expectEqualStrings("{deep: {...}}", schema);
}

test "inferCompactSchema scalars and empty array" {
    var p = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"s\":\"a\",\"n\":2,\"b\":true,\"z\":null,\"arr\":[]}", .{});
    defer p.deinit();
    const schema = try inferCompactSchema(testing.allocator, p.value, 2);
    defer testing.allocator.free(schema);
    try testing.expectEqualStrings("{s: string, n: number, b: boolean, z: null, arr: []}", schema);
}

test "transform spills a binary resource blob and names the saved path and size" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spill_dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(spill_dir);

    // base64 of the 5 bytes {0,1,2,255,254} (AAEC//4=).
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[
        \\  {"type":"resource","resource":{"uri":"file:///blob.bin","mimeType":"application/octet-stream","blob":"AAEC//4="}}
        \\]}}
    ;
    const out = try extractToolCallResultTextCtx(testing.allocator, raw, .{
        .server_name = "blob-server",
        .spill_dir = spill_dir,
    });
    defer testing.allocator.free(out);

    // The emitted text names a file under the spill dir and the byte size (5).
    try testing.expect(std.mem.indexOf(u8, out, spill_dir) != null);
    try testing.expect(std.mem.indexOf(u8, out, "5 bytes") != null);
    // And the file actually exists on disk with the decoded bytes.
    // Pull the path out of the saved message: it ends with the path then `]`.
    const close = std.mem.lastIndexOfScalar(u8, out, ']') orelse unreachable;
    const to_idx = std.mem.indexOf(u8, out, " to ") orelse unreachable;
    const path = out[to_idx + 4 .. close];
    const bytes = try std.Io.Dir.cwd().readFileAlloc(rt_io_for_test(), path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0xff, 0xfe }, bytes);
}

test "transform spills an oversized text result via shouldSpill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const spill_dir = try test_helpers.tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(spill_dir);

    // Build a >100KB text content block.
    const big_len = output_limits.MAX_RESULT_INLINE + 1024;
    const big = try testing.allocator.alloc(u8, big_len);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    var body = std_io.StringBuilder.init(testing.allocator);
    defer body.deinit();
    try body.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
    try body.appendSlice(big);
    try body.appendSlice("\"}]}}");

    const out = try extractToolCallResultTextCtx(testing.allocator, body.items(), .{
        .server_name = "big-server",
        .spill_dir = spill_dir,
    });
    defer testing.allocator.free(out);

    // The huge result is replaced by a small pointer block, not inlined.
    try testing.expect(out.len < big_len);
    try testing.expect(std.mem.indexOf(u8, out, spill_dir) != null);
    try testing.expect(std.mem.indexOf(u8, out, "saved to") != null);
}

// -- mcp-13 reconnect / session-expiry tests --

test "parseRpcErrorCode extracts the code from a top-level error" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"Session not found"}}
    ;
    try testing.expectEqual(@as(?i64, -32001), parseRpcErrorCode(testing.allocator, raw));
}

test "parseRpcErrorCode extracts the code from an error nested under result" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"error":{"code":-32601,"message":"nope"}}}
    ;
    try testing.expectEqual(@as(?i64, -32601), parseRpcErrorCode(testing.allocator, raw));
}

test "parseRpcErrorCode returns null when there is no error object" {
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"content":[]}}
    ;
    try testing.expectEqual(@as(?i64, null), parseRpcErrorCode(testing.allocator, raw));
}

test "isSessionExpired requires 404 and code -32001" {
    try testing.expect(isSessionExpired(404, -32001));
    // 404 with a different code is not session expiry.
    try testing.expect(!isSessionExpired(404, -32600));
    // -32001 under a non-404 status is not session expiry (reference keys on 404).
    try testing.expect(!isSessionExpired(200, -32001));
    // 404 with no code at all is not session expiry.
    try testing.expect(!isSessionExpired(404, null));
}

/// Test-only accessor for the runtime io handle (the test runner installs it).
fn rt_io_for_test() std.Io {
    return @import("zcode_runtime").io;
}
