//! Phase 9 Task 11 (tools-09): StructuredOutput tool for non-interactive
//! structured JSON output.
//!
//! Ported from claude-code-main/src/tools/SyntheticOutputTool/SyntheticOutputTool.ts.
//! In a non-interactive (one-shot) session, this tool is auto-added to the tool
//! set, accepts a caller-supplied JSON schema (the active response schema from
//! `--json <schema>` / `pending_response_schema`), validates the model's output
//! against it, and returns the structured object as the session's final result.
//!
//! Reference behavior:
//!  - `SYNTHETIC_OUTPUT_TOOL_NAME = 'StructuredOutput'` (line 20).
//!  - `isSyntheticOutputToolEnabled` = non-interactive only (lines 22-26): the
//!    tool is created (and thus enabled) only when the session is one-shot.
//!  - `call` validates the input against the compiled caller schema; on mismatch
//!    throws `Output does not match required schema: <errors>` so the model
//!    retries; on success returns `structured_output: input` (lines 116-163).
//!  - The tool's input schema IS the caller schema; when none is supplied the
//!    reference passes `z.object({}).passthrough()` -- accept any object (line 11).
//!
//! Scope / deviations. The reference compiles the schema with ajv (a full
//! JSON-Schema validator). Per CLAUDE.md rule 2 ("simplicity first") we port only
//! the subset ajv exercises here in practice: object/array/string/number/integer/
//! boolean type checks, `required` keys, and `enum` membership on the top-level
//! object. Anything fancier (nested $ref, allOf/oneOf, format assertions) is
//! speculative and intentionally not implemented. The non-interactive gating and
//! the "extract final structured result" step are factored into pure functions so
//! they are unit-testable without driving the live agent loop (the end-to-end
//! `--json` flow is verified manually -- see the phase Verification section).

const std = @import("std");
const parse_helpers = @import("../core/parse_helpers.zig");

/// The tool name the model calls. Verbatim from the reference
/// (SyntheticOutputTool.ts:20).
pub const TOOL_NAME = "StructuredOutput";

/// The model-facing prompt/usage hint. Verbatim from the reference
/// (SyntheticOutputTool.ts:50-52).
pub const PROMPT =
    "Use this tool to return your final response in the requested structured " ++
    "format. You MUST call this tool exactly once at the end of your response " ++
    "to provide the structured output.";

/// True when the StructuredOutput tool should be added to the tool set. Mirrors
/// `isSyntheticOutputToolEnabled` (SyntheticOutputTool.ts:22-26): the tool is
/// enabled only in a non-interactive (one-shot) session. Pure so the schema
/// collector and any gating call site can consult it. The reference creates the
/// tool only when non-interactive; once created it is always enabled, so the
/// gating reduces to "non-interactive session".
pub fn isEnabled(non_interactive: bool) bool {
    return non_interactive;
}

/// Result of validating a candidate structured-output object against the caller
/// schema. On failure `error_message` is an owned diagnostic string in the
/// reference's `Output does not match required schema: <details>` shape; the
/// model reads it and retries. On success `error_message` is null.
pub const ValidationResult = struct {
    ok: bool,
    /// Owned when present. Caller frees. Null on success.
    error_message: ?[]u8 = null,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |m| allocator.free(m);
        self.error_message = null;
    }
};

/// Validate a candidate JSON object string against a caller JSON-schema string.
///
/// `schema_json` is the caller's JSON Schema (the active response schema). When
/// it is null or empty, any object is accepted (mirrors the reference's
/// `z.object({}).passthrough()` default when no schema is supplied).
///
/// Supported schema subset (the ajv usage the reference actually exercises):
///  - top-level `type` must be "object" (other top-level types accept anything);
///  - `required`: every listed key must be present in the candidate;
///  - `properties.<k>.type`: the candidate value's JSON type must match
///    (`string`/`number`/`integer`/`boolean`/`array`/`object`); `integer`
///    additionally requires a whole number;
///  - `properties.<k>.enum`: the candidate value must equal one of the enum
///    entries (compared structurally for scalars).
///
/// Returns an owned ValidationResult. On a malformed candidate (not parseable as
/// JSON, or not an object when the schema demands one) it fails with a clear
/// message rather than erroring, so the model can self-correct.
pub fn validate(
    allocator: std.mem.Allocator,
    schema_json: ?[]const u8,
    candidate_json: []const u8,
) !ValidationResult {
    // Parse the candidate first; an unparseable candidate is always a failure.
    const cand_trimmed = std.mem.trim(u8, candidate_json, " \t\r\n");
    var cand_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        cand_trimmed,
        parse_helpers.json_parse_options,
    ) catch {
        return failure(allocator, "root: value is not valid JSON");
    };
    defer cand_parsed.deinit();

    // No schema -> accept any object (reference passthrough default). The
    // reference's base input schema is `z.object({})` so the candidate must at
    // least be an object.
    const schema_str = schema_json orelse "";
    const schema_trimmed = std.mem.trim(u8, schema_str, " \t\r\n");
    if (schema_trimmed.len == 0) {
        if (cand_parsed.value != .object) {
            return failure(allocator, "root: expected an object");
        }
        return ValidationResult{ .ok = true };
    }

    var schema_parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        schema_trimmed,
        parse_helpers.json_parse_options,
    ) catch {
        // A broken schema cannot fail the candidate -- accept (mirrors the
        // reference returning {error} at tool-build time, never at call time,
        // for a bad schema; here we degrade to passthrough rather than block).
        return ValidationResult{ .ok = true };
    };
    defer schema_parsed.deinit();

    if (schema_parsed.value != .object) {
        return ValidationResult{ .ok = true };
    }
    const schema_obj = schema_parsed.value.object;

    // Only object schemas constrain the candidate in our subset. A non-object
    // top-level `type` accepts anything.
    const type_val = schema_obj.get("type");
    const is_object_schema = blk: {
        if (type_val) |t| {
            if (t == .string) break :blk std.mem.eql(u8, t.string, "object");
        }
        // No explicit type but has `properties`/`required` -> treat as object.
        break :blk schema_obj.contains("properties") or schema_obj.contains("required");
    };
    if (!is_object_schema) {
        return ValidationResult{ .ok = true };
    }

    if (cand_parsed.value != .object) {
        return failure(allocator, "root: expected an object");
    }
    const cand_obj = cand_parsed.value.object;

    // required: every listed key must be present.
    if (schema_obj.get("required")) |req_val| {
        if (req_val == .array) {
            for (req_val.array.items) |req_item| {
                if (req_item != .string) continue;
                const key = req_item.string;
                if (!cand_obj.contains(key)) {
                    return failureFmt(allocator, "{s}: required property is missing", .{key});
                }
            }
        }
    }

    // properties.<k>.type / enum: validate each present property.
    if (schema_obj.get("properties")) |props_val| {
        if (props_val == .object) {
            var it = props_val.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const prop_schema = entry.value_ptr.*;
                if (prop_schema != .object) continue;
                const cand_value = cand_obj.get(key) orelse continue; // absent: required handled it

                // type check
                if (prop_schema.object.get("type")) |pt| {
                    if (pt == .string) {
                        if (!jsonTypeMatches(pt.string, cand_value)) {
                            return failureFmt(
                                allocator,
                                "{s}: expected type {s}",
                                .{ key, pt.string },
                            );
                        }
                    }
                }

                // enum membership
                if (prop_schema.object.get("enum")) |en| {
                    if (en == .array) {
                        if (!enumContains(en.array.items, cand_value)) {
                            return failureFmt(
                                allocator,
                                "{s}: value not in allowed enum",
                                .{key},
                            );
                        }
                    }
                }
            }
        }
    }

    return ValidationResult{ .ok = true };
}

/// Does `cand`'s JSON type satisfy the JSON-Schema `type` keyword? `integer`
/// additionally requires the number to be whole.
fn jsonTypeMatches(schema_type: []const u8, cand: std.json.Value) bool {
    if (std.mem.eql(u8, schema_type, "string")) return cand == .string;
    if (std.mem.eql(u8, schema_type, "boolean")) return cand == .bool;
    if (std.mem.eql(u8, schema_type, "array")) return cand == .array;
    if (std.mem.eql(u8, schema_type, "object")) return cand == .object;
    if (std.mem.eql(u8, schema_type, "null")) return cand == .null;
    if (std.mem.eql(u8, schema_type, "number")) {
        return cand == .integer or cand == .float or cand == .number_string;
    }
    if (std.mem.eql(u8, schema_type, "integer")) {
        if (cand == .integer) return true;
        if (cand == .float) return @floor(cand.float) == cand.float;
        return false;
    }
    // Unknown type keyword: do not reject.
    return true;
}

/// Structural equality between a candidate JSON value and one enum entry, for
/// the scalar cases JSON Schema `enum` is used for in practice (strings,
/// numbers, booleans, null).
fn jsonScalarEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .string => b == .string and std.mem.eql(u8, a.string, b.string),
        .bool => b == .bool and a.bool == b.bool,
        .null => b == .null,
        .integer => switch (b) {
            .integer => a.integer == b.integer,
            .float => @as(f64, @floatFromInt(a.integer)) == b.float,
            else => false,
        },
        .float => switch (b) {
            .float => a.float == b.float,
            .integer => a.float == @as(f64, @floatFromInt(b.integer)),
            else => false,
        },
        .number_string => b == .number_string and std.mem.eql(u8, a.number_string, b.number_string),
        else => false,
    };
}

fn enumContains(entries: []const std.json.Value, cand: std.json.Value) bool {
    for (entries) |e| {
        if (jsonScalarEql(cand, e)) return true;
    }
    return false;
}

fn failure(allocator: std.mem.Allocator, detail: []const u8) !ValidationResult {
    const msg = try std.fmt.allocPrint(
        allocator,
        "Output does not match required schema: {s}",
        .{detail},
    );
    return ValidationResult{ .ok = false, .error_message = msg };
}

fn failureFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !ValidationResult {
    const detail = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(detail);
    return failure(allocator, detail);
}

/// Extract the final structured result that the `--json` path should emit when
/// the model calls StructuredOutput. The reference returns
/// `structured_output: input` -- i.e. the validated tool input itself becomes
/// the structured result. We mirror that: the final JSON the session emits is a
/// canonical re-serialization of the validated candidate object.
///
/// `candidate_json` MUST already have passed `validate`. Returns an owned
/// minified JSON string the caller emits as the session's final output. Factored
/// out (instead of inlined into the handler) so the "what gets emitted" contract
/// is directly unit-testable per the acceptance criteria.
pub fn extractFinalResult(
    allocator: std.mem.Allocator,
    candidate_json: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, candidate_json, " \t\r\n");
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        trimmed,
        parse_helpers.json_parse_options,
    ) catch {
        // Should not happen post-validate, but degrade to echoing the input.
        return allocator.dupe(u8, trimmed);
    };
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

/// Dispatch entry point. Validates `candidate_json` against the active
/// `schema_json` (the caller's response schema, or null for passthrough). On
/// failure returns the owned `Output does not match required schema: ...`
/// message so the model retries. On success returns the canonical structured
/// JSON (the validated input) which the session treats as the final output.
pub fn run(
    allocator: std.mem.Allocator,
    schema_json: ?[]const u8,
    candidate_json: []const u8,
) ![]u8 {
    var result = try validate(allocator, schema_json, candidate_json);
    if (!result.ok) {
        // Hand the owned message to the caller; clear the struct's pointer so
        // its deinit does not double-free.
        const msg = result.error_message.?;
        result.error_message = null;
        return msg;
    }
    return extractFinalResult(allocator, candidate_json);
}

// --- Tests ---

const testing = std.testing;

test "isEnabled gates on non-interactive sessions only" {
    // Present in the non-interactive tool set, absent in interactive.
    try testing.expect(isEnabled(true));
    try testing.expect(!isEnabled(false));
}

test "validator accepts object matching {required:[a], properties:{a:string}}" {
    const schema = "{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{\"type\":\"string\"}}}";

    var ok = try validate(testing.allocator, schema, "{\"a\":\"hello\"}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok);
    try testing.expect(ok.error_message == null);
}

test "validator rejects object missing a required key" {
    const schema = "{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{\"type\":\"string\"}}}";

    var bad = try validate(testing.allocator, schema, "{\"b\":\"oops\"}");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.startsWith(u8, bad.error_message.?, "Output does not match required schema:"));
    try testing.expect(std.mem.indexOf(u8, bad.error_message.?, "a:") != null);
}

test "validator rejects object with wrong property type" {
    const schema = "{\"type\":\"object\",\"required\":[\"a\"],\"properties\":{\"a\":{\"type\":\"string\"}}}";

    var bad = try validate(testing.allocator, schema, "{\"a\":123}");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.indexOf(u8, bad.error_message.?, "expected type string") != null);
}

test "validator enforces enum membership" {
    const schema = "{\"type\":\"object\",\"properties\":{\"color\":{\"type\":\"string\",\"enum\":[\"red\",\"green\"]}}}";

    var ok = try validate(testing.allocator, schema, "{\"color\":\"red\"}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok);

    var bad = try validate(testing.allocator, schema, "{\"color\":\"blue\"}");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.indexOf(u8, bad.error_message.?, "enum") != null);
}

test "validator validates integer type" {
    const schema = "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}}}";

    var ok = try validate(testing.allocator, schema, "{\"n\":42}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok);

    var bad = try validate(testing.allocator, schema, "{\"n\":\"42\"}");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
}

test "validator passes through when no schema supplied" {
    var ok = try validate(testing.allocator, null, "{\"anything\":true}");
    defer ok.deinit(testing.allocator);
    try testing.expect(ok.ok);

    var ok2 = try validate(testing.allocator, "", "{\"x\":1,\"y\":[1,2,3]}");
    defer ok2.deinit(testing.allocator);
    try testing.expect(ok2.ok);

    // Even with no schema, a non-object candidate fails (base z.object({})).
    var bad = try validate(testing.allocator, null, "\"just a string\"");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
}

test "validator rejects unparseable candidate" {
    var bad = try validate(testing.allocator, null, "{not valid json");
    defer bad.deinit(testing.allocator);
    try testing.expect(!bad.ok);
    try testing.expect(std.mem.indexOf(u8, bad.error_message.?, "not valid JSON") != null);
}

test "extractFinalResult emits the validated input as canonical JSON" {
    // The validated input IS the structured result (reference: structured_output: input).
    const out = try extractFinalResult(testing.allocator, "  {\"a\":\"hi\",\"b\":7}  ");
    defer testing.allocator.free(out);
    // Re-serialized canonically (no surrounding whitespace, key order preserved).
    try testing.expectEqualStrings("{\"a\":\"hi\",\"b\":7}", out);
}

test "run returns the structured JSON on a valid call" {
    const schema = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}";
    const out = try run(testing.allocator, schema, "{\"name\":\"zcode\"}");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"name\":\"zcode\"}", out);
}

test "run returns the schema-mismatch message on an invalid call" {
    const schema = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}";
    const out = try run(testing.allocator, schema, "{\"name\":99}");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "Output does not match required schema:"));
}
