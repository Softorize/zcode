const std = @import("std");
const std_io = @import("../core/std_io.zig");
const parse_helpers = @import("../core/parse_helpers.zig");

pub const TokenUsage = struct {
    input_tokens: ?usize = null,
    output_tokens: ?usize = null,
    // Anthropic-specific cache accounting. Optional (null != 0) so providers
    // that omit these fields do not falsely report zero cache usage.
    cache_read_input_tokens: ?usize = null,
    cache_creation_input_tokens: ?usize = null,
    // Anthropic server_tool_use.web_search_requests count.
    web_search_requests: ?usize = null,
};

pub fn extractTokenUsage(allocator: std.mem.Allocator, response_json: []const u8) TokenUsage {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return .{};
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return .{};

    // OpenAI/DeepSeek/Ollama-like usage object. Anthropic responses also use a
    // top-level `usage` object with `input_tokens`/`output_tokens`, so this
    // branch catches them via the fallbacks below; the cache/web-search fields
    // are Anthropic-only and stay null for the other providers (they omit them).
    if (root.object.get("usage")) |usage| {
        if (usage == .object) {
            var out: TokenUsage = .{};
            out.input_tokens = getIntField(usage.object, "prompt_tokens") orelse getIntField(usage.object, "input_tokens");
            out.output_tokens = getIntField(usage.object, "completion_tokens") orelse getIntField(usage.object, "output_tokens");
            extractAnthropicCacheFields(usage.object, &out);
            if (out.input_tokens != null or out.output_tokens != null) return out;
        }
    }

    // Anthropic usage object.
    if (root.object.get("usage")) |usage2| {
        if (usage2 == .object) {
            var out2: TokenUsage = .{};
            out2.input_tokens = getIntField(usage2.object, "input_tokens");
            out2.output_tokens = getIntField(usage2.object, "output_tokens");
            extractAnthropicCacheFields(usage2.object, &out2);
            if (out2.input_tokens != null or out2.output_tokens != null) return out2;
        }
    }

    // Gemini usage metadata.
    if (root.object.get("usageMetadata")) |usage_meta| {
        if (usage_meta == .object) {
            var out3: TokenUsage = .{};
            out3.input_tokens = getIntField(usage_meta.object, "promptTokenCount");
            out3.output_tokens = getIntField(usage_meta.object, "candidatesTokenCount") orelse getIntField(usage_meta.object, "responseTokenCount");
            if (out3.input_tokens != null or out3.output_tokens != null) return out3;
        }
    }

    // Ollama top-level counters.
    var out4: TokenUsage = .{};
    out4.input_tokens = getIntField(root.object, "prompt_eval_count");
    out4.output_tokens = getIntField(root.object, "eval_count");
    if (out4.input_tokens != null or out4.output_tokens != null) return out4;

    return .{};
}

/// Pull Anthropic cache-token and web-search counts out of a `usage` object.
/// `cache_read_input_tokens` / `cache_creation_input_tokens` sit directly on
/// the usage object; `web_search_requests` is nested under `server_tool_use`.
/// All three stay null when absent so non-Anthropic providers report null,
/// not a misleading zero. `getIntField` already guards negatives/overflow.
fn extractAnthropicCacheFields(obj: std.json.ObjectMap, out: *TokenUsage) void {
    out.cache_read_input_tokens = getIntField(obj, "cache_read_input_tokens");
    out.cache_creation_input_tokens = getIntField(obj, "cache_creation_input_tokens");
    if (obj.get("server_tool_use")) |stu| {
        if (stu == .object) {
            out.web_search_requests = getIntField(stu.object, "web_search_requests");
        }
    }
}

fn getIntField(obj: std.json.ObjectMap, key: []const u8) ?usize {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        // `std.math.cast` returns null on overflow. On 32-bit targets
        // a valid i64 JSON integer (e.g. a large token count) can
        // exceed usize=u32 and would otherwise panic on @intCast.
        .integer => |n| if (n < 0) null else std.math.cast(usize, n),
        .number_string => |s| std.fmt.parseInt(usize, s, 10) catch null,
        else => null,
    };
}

/// Concatenate `delta.reasoning_content` (SSE) or
/// `choices[0].message.reasoning_content` / `message.reasoning_content`
/// (non-streaming) into a single string. Returns an empty owned slice
/// when no reasoning is present. The agent loop reads this to tell
/// apart "model returned literally nothing" (auto-retry) from "model
/// reasoned but produced no content" (don't auto-retry).
pub fn extractReasoningText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();

    if (std.mem.indexOf(u8, raw, "data:") != null) {
        var lines = std.mem.splitScalar(u8, raw, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
            const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]") or data.len == 0 or data[0] != '{') continue;

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var parsed = parse_helpers.parseJsonBounded(std.json.Value, arena.allocator(), data) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            if (parsed.value.object.get("choices")) |choices| {
                if (choices == .array and choices.array.items.len > 0 and choices.array.items[0] == .object) {
                    if (choices.array.items[0].object.get("delta")) |delta| {
                        if (delta == .object) {
                            if (delta.object.get("reasoning_content")) |rc| {
                                if (rc == .string and rc.string.len > 0) {
                                    try out.writer().writeAll(rc.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        return out.toOwnedSlice();
    }

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, raw) catch return allocator.dupe(u8, "");
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "");

    if (parsed.value.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0 and choices.array.items[0] == .object) {
            if (choices.array.items[0].object.get("message")) |m| {
                if (m == .object) {
                    if (m.object.get("reasoning_content")) |rc| {
                        if (rc == .string and rc.string.len > 0) {
                            try out.writer().writeAll(rc.string);
                        }
                    }
                }
            }
        }
    }
    if (parsed.value.object.get("message")) |m| {
        if (m == .object) {
            if (m.object.get("reasoning_content")) |rc| {
                if (rc == .string and rc.string.len > 0) {
                    try out.writer().writeAll(rc.string);
                }
            }
        }
    }
    return out.toOwnedSlice();
}

pub fn parseSseText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, raw, "data:") == null) {
        return allocator.dupe(u8, raw);
    }

    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    var saw_json_payload_without_text = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
        if (std.mem.eql(u8, data, "[DONE]") or data.len == 0) continue;

        if (extractStreamingTextPiece(allocator, data)) |piece| {
            defer allocator.free(piece);
            try out.writer().writeAll(piece);
        } else {
            if (looksLikeJsonPayload(data)) {
                saw_json_payload_without_text = true;
                continue;
            }
            try out.writer().writeAll(data);
        }
    }

    if (out.items().len == 0) {
        if (saw_json_payload_without_text) {
            // Caller can fall back to non-stream send() instead of printing raw JSON chunks.
            return allocator.dupe(u8, "");
        }
        return allocator.dupe(u8, raw);
    }
    return out.toOwnedSlice();
}

/// Extract tool calls from raw SSE event data. Handles both:
/// - Anthropic: content_block_start(tool_use) + input_json_delta events
/// - OpenAI: delta.tool_calls with accumulated function.arguments
///
/// Returns a JSON array string like `[{"name":"Read","args":"{...}"}]`
/// or empty string if no tool calls found.
pub fn parseSseToolCalls(allocator: std.mem.Allocator, raw: []const u8) []u8 {
    // Track up to 16 concurrent tool calls
    var names: [16][]u8 = undefined; // owned dupes, not arena-borrowed
    var names_owned: usize = 0;
    var args_bufs: [16]std_io.StringBuilder = undefined;
    var tool_count: usize = 0;

    // Initialize args buffers
    for (&args_bufs) |*buf| {
        buf.* = std_io.StringBuilder.init(allocator);
    }
    defer {
        for (args_bufs[0..tool_count]) |*buf| buf.deinit();
        for (names[0..names_owned]) |n| allocator.free(n);
    }

    // Single arena for all JSON parsing -- previous version created one
    // per SSE line which was wasteful on streams with hundreds of lines.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trim(u8, trimmed["data:".len..], " \t");
        if (data.len == 0 or data[0] != '{') continue;

        // Reset arena each iteration to bound memory usage while
        // keeping a single init/deinit pair for the outer loop.
        _ = arena.reset(.retain_capacity);
        var parsed = parse_helpers.parseJsonBounded(std.json.Value, arena.allocator(), data) catch continue;
        defer parsed.deinit();
        const obj = if (parsed.value == .object) parsed.value.object else continue;

        // Anthropic: content_block_start with tool_use
        if (obj.get("type")) |typ| {
            if (typ == .string and std.mem.eql(u8, typ.string, "content_block_start")) {
                if (obj.get("content_block")) |cb| {
                    if (cb == .object) {
                        if (cb.object.get("type")) |cbt| {
                            if (cbt == .string and std.mem.eql(u8, cbt.string, "tool_use")) {
                                if (cb.object.get("name")) |name_val| {
                                    if (name_val == .string and tool_count < names.len) {
                                        names[tool_count] = allocator.dupe(u8, name_val.string) catch continue;
                                        names_owned = tool_count + 1;
                                        tool_count += 1;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // Anthropic: input_json_delta
            if (typ == .string and std.mem.eql(u8, typ.string, "content_block_delta")) {
                if (obj.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("type")) |dt| {
                            if (dt == .string and std.mem.eql(u8, dt.string, "input_json_delta")) {
                                if (delta.object.get("partial_json")) |pj| {
                                    if (pj == .string and tool_count > 0) {
                                        args_bufs[tool_count - 1].appendSlice(pj.string) catch {};
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // OpenAI: delta.tool_calls
        if (obj.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const first = choices.array.items[0];
                if (first == .object) {
                    if (first.object.get("delta")) |delta| {
                        if (delta == .object) {
                            if (delta.object.get("tool_calls")) |tc| {
                                if (tc == .array) {
                                    for (tc.array.items) |tc_item| {
                                        if (tc_item != .object) continue;
                                        // New tool call
                                        if (tc_item.object.get("function")) |func| {
                                            if (func == .object) {
                                                if (func.object.get("name")) |name_val| {
                                                    if (name_val == .string and tool_count < names.len) {
                                                        names[tool_count] = allocator.dupe(u8, name_val.string) catch continue;
                                                        names_owned = tool_count + 1;
                                                        tool_count += 1;
                                                    }
                                                }
                                                if (func.object.get("arguments")) |args_val| {
                                                    if (args_val == .string and tool_count > 0) {
                                                        args_bufs[tool_count - 1].appendSlice(args_val.string) catch {};
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (tool_count == 0) return allocator.dupe(u8, "") catch "";

    // Build the tool_calls JSON array
    var out = std_io.StringBuilder.init(allocator);
    out.writer().writeByte('[') catch return allocator.dupe(u8, "") catch "";
    for (names[0..tool_count], 0..) |name, i| {
        if (i > 0) out.writer().writeAll(",") catch {};
        out.writer().writeAll("{\"name\":\"") catch {};
        writeJsonEscapedString(&out, name);
        out.writer().writeAll("\",\"args\":\"") catch {};
        writeJsonEscapedString(&out, args_bufs[i].items());
        out.writer().writeAll("\"}") catch {};
    }
    out.writer().writeByte(']') catch {};
    return out.toOwnedSlice() catch allocator.dupe(u8, "") catch "";
}

fn looksLikeJsonPayload(data: []const u8) bool {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return false;
    return trimmed[0] == '{' or trimmed[0] == '[';
}

pub fn extractStreamingTextPiece(allocator: std.mem.Allocator, data: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = parse_helpers.parseJsonBounded(std.json.Value, arena.allocator(), data) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0 and choices.array.items[0] == .object) {
            const first = choices.array.items[0].object;
            if (first.get("delta")) |delta| {
                if (delta == .object) {
                    if (delta.object.get("content")) |c| {
                        if (c == .string) return allocator.dupe(u8, c.string) catch null;
                    }
                    // delta.reasoning_content (kimi-k2.6, DeepSeek-R1,
                    // Qwen3-thinking) is intentionally NOT surfaced.
                    // Surfacing it spams the transcript with the
                    // model's internal monologue. The non-streaming
                    // extractor (extractOpenAI below) still falls
                    // back to reasoning_content when content is
                    // genuinely empty so a pure-reasoning turn isn't
                    // lost.
                }
            }
        }
    }

    if (root.object.get("type")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "content_block_delta")) {
            if (root.object.get("delta")) |delta| {
                if (delta == .object) {
                    if (delta.object.get("text")) |txt| {
                        if (txt == .string) return allocator.dupe(u8, txt.string) catch null;
                    }
                }
            }
        }
    }

    if (root.object.get("message")) |m| {
        if (m == .object) {
            if (m.object.get("content")) |c| {
                if (c == .string and c.string.len > 0) return allocator.dupe(u8, c.string) catch null;
            }
            // Fall back to thinking / reasoning_content fields so that
            // reasoning-mode models (Qwen3, DeepSeek-R1, abliterated
            // variants) show their output instead of rendering nothing
            // while the user waits. Without this, a model that emits
            // only thinking tokens produced an empty stream and the
            // spinner stuck on "thinking" with no visible output.
            if (m.object.get("thinking")) |t| {
                if (t == .string and t.string.len > 0) return allocator.dupe(u8, t.string) catch null;
            }
            if (m.object.get("reasoning_content")) |rc| {
                if (rc == .string and rc.string.len > 0) return allocator.dupe(u8, rc.string) catch null;
            }
        }
    }

    return null;
}

pub fn extractFirstText(allocator: std.mem.Allocator, response_json: []const u8) ![]u8 {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch {
        return allocator.dupe(u8, response_json);
    };
    defer parsed.deinit();

    const root = parsed.value;

    if (root == .object) {
        if (extractOpenAI(root.object)) |text| {
            return allocator.dupe(u8, text);
        }
        if (extractAnthropic(allocator, root.object)) |text| {
            return text;
        }
        // Anthropic responses with only tool_use blocks (no text blocks)
        // have a content array but extractAnthropic returns null because
        // collectTextFields finds no "text" entries. Without this guard,
        // the raw JSON would be returned as the "text" and displayed to
        // the user. Return empty string so the agent runtime treats it
        // as a tool-only turn.
        if (isAnthropicResponse(root.object)) {
            return allocator.dupe(u8, "");
        }
        if (extractGemini(allocator, root.object)) |text| {
            return text;
        }
        if (extractOllama(root.object)) |text| {
            return allocator.dupe(u8, text);
        }
    }

    return allocator.dupe(u8, response_json);
}

fn extractOpenAI(obj: std.json.ObjectMap) ?[]const u8 {
    const choices = obj.get("choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;

    const first = choices.array.items[0];
    if (first != .object) return null;

    const message = first.object.get("message") orelse return null;
    if (message != .object) return null;

    if (message.object.get("content")) |content| {
        if (content == .string and content.string.len > 0) {
            return content.string;
        }
    }
    if (message.object.get("reasoning_content")) |reasoning| {
        if (reasoning == .string and reasoning.string.len > 0) {
            return reasoning.string;
        }
    }

    // If content is null/empty but tool_calls exist, return empty string
    // (not null) so the caller knows this is a valid OpenAI response
    if (message.object.get("tool_calls")) |tc| {
        if (tc == .array and tc.array.items.len > 0) {
            return "";
        }
    }

    return null;
}

fn extractAnthropic(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?[]u8 {
    const content = obj.get("content") orelse return null;
    if (content != .array or content.array.items.len == 0) return null;
    return collectTextFields(allocator, content.array.items, "text");
}

/// Returns true if the response looks like an Anthropic Messages API
/// envelope (has "type":"message" and a "content" array). Used to
/// distinguish tool-only Anthropic responses from unknown formats
/// so we return "" instead of dumping the raw JSON.
fn isAnthropicResponse(obj: std.json.ObjectMap) bool {
    if (obj.get("type")) |typ| {
        if (typ == .string and std.mem.eql(u8, typ.string, "message")) return true;
    }
    // Also match if there's a content array with tool_use entries
    if (obj.get("content")) |content| {
        if (content == .array) return true;
    }
    return false;
}

fn extractGemini(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ?[]u8 {
    const candidates = obj.get("candidates") orelse return null;
    if (candidates != .array or candidates.array.items.len == 0) return null;

    const first_candidate = candidates.array.items[0];
    if (first_candidate != .object) return null;

    const content = first_candidate.object.get("content") orelse return null;
    if (content != .object) return null;

    const parts = content.object.get("parts") orelse return null;
    if (parts != .array or parts.array.items.len == 0) return null;
    return collectTextFields(allocator, parts.array.items, "text");
}

fn extractOllama(obj: std.json.ObjectMap) ?[]const u8 {
    const message = obj.get("message") orelse return null;
    if (message != .object) return null;

    const content = message.object.get("content") orelse return null;
    if (content != .string) return null;

    return content.string;
}

fn collectTextFields(allocator: std.mem.Allocator, items: []const std.json.Value, field: []const u8) ?[]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (items) |item| {
        if (item != .object) continue;
        const text = item.object.get(field) orelse continue;
        if (text != .string or text.string.len == 0) continue;
        out.appendSlice(text.string) catch return null;
    }

    if (out.items().len == 0) {
        out.deinit();
        return null;
    }

    return out.toOwnedSlice() catch null;
}

/// Build zcode's canonical `[{"name","args"},...]` tool-calls array
/// from an Anthropic-style content[] slice. Each `tool_use` entry
/// becomes one output object; the `input` field is stringified so
/// it matches zcode's existing "args is a JSON-string" contract.
/// Non-tool_use entries (plain text blocks, thinking blocks) are
/// skipped.
fn extractAnthropicToolUse(allocator: std.mem.Allocator, items: []const std.json.Value) []const u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    out.writer().writeByte('[') catch {
        out.deinit();
        return "";
    };

    var count: usize = 0;
    for (items) |entry| {
        if (entry != .object) continue;
        const typ = entry.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "tool_use")) continue;
        const name_val = entry.object.get("name") orelse continue;
        if (name_val != .string) continue;

        if (count > 0) out.writer().writeAll(",") catch continue;
        out.writer().writeAll("{\"name\":\"") catch continue;
        writeJsonEscapedString(&out, name_val.string);
        out.writer().writeAll("\",\"args\":\"") catch continue;

        if (entry.object.get("input")) |input| {
            // Anthropic's input is an object; serialize it to a JSON
            // string and then escape that string for embedding inside
            // a JSON string field (matches the Ollama code path).
            var obj_buf = std_io.StringBuilder.init(allocator);
            defer obj_buf.deinit();
            obj_buf.writer().print("{f}", .{std.json.fmt(input, .{})}) catch continue;
            writeJsonEscapedString(&out, obj_buf.items());
        } else {
            out.writer().writeAll("{}") catch continue;
        }

        out.writer().writeAll("\"}") catch continue;
        count += 1;
    }

    out.writer().writeByte(']') catch {
        out.deinit();
        return "";
    };
    if (count == 0) {
        out.deinit();
        return "";
    }
    return out.toOwnedSlice() catch "";
}

pub fn extractNativeToolCalls(allocator: std.mem.Allocator, response_json: []const u8) []const u8 {
    var parsed = parse_helpers.parseJsonBounded(std.json.Value, allocator, response_json) catch return "";
    defer parsed.deinit();

    if (parsed.value != .object) return "";

    // Anthropic's tool_use format is top-level content[] with entries of
    // type "tool_use" that carry `name` and `input` (object). Detect it
    // first because the presence of a top-level content array is a
    // strong signal -- OpenAI and Ollama don't produce one at the root.
    if (parsed.value.object.get("content")) |content| {
        if (content == .array and content.array.items.len > 0) {
            // Only treat this as Anthropic if we see at least one tool_use entry.
            var has_tool_use = false;
            for (content.array.items) |entry| {
                if (entry != .object) continue;
                const typ = entry.object.get("type") orelse continue;
                if (typ != .string) continue;
                if (std.mem.eql(u8, typ.string, "tool_use")) {
                    has_tool_use = true;
                    break;
                }
            }
            if (has_tool_use) {
                return extractAnthropicToolUse(allocator, content.array.items);
            }
        }
    }

    // Try OpenAI format: choices[0].message.tool_calls
    // Then Ollama format: message.tool_calls
    const tool_calls = blk: {
        if (parsed.value.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const first = choices.array.items[0];
                if (first == .object) {
                    if (first.object.get("message")) |msg| {
                        if (msg == .object) {
                            if (msg.object.get("tool_calls")) |tc| break :blk tc;
                        }
                    }
                }
            }
        }
        // Ollama format: message.tool_calls at top level.
        if (parsed.value.object.get("message")) |msg| {
            if (msg == .object) {
                if (msg.object.get("tool_calls")) |tc| break :blk tc;
            }
        }
        return "";
    };
    if (tool_calls != .array or tool_calls.array.items.len == 0) return "";

    // Build a simplified tool_calls JSON array: [{"name":"...","args":"..."},...]
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    out.writer().writeByte('[') catch {
        out.deinit();
        return "";
    };

    var count: usize = 0;
    for (tool_calls.array.items) |tc| {
        if (tc != .object) continue;
        const func = tc.object.get("function") orelse continue;
        if (func != .object) continue;
        const name_val = func.object.get("name") orelse continue;
        if (name_val != .string) continue;
        const args_val = func.object.get("arguments") orelse continue;

        // Build each entry in a scratch buffer so a partial write failure
        // cannot leave `out` in a malformed state (e.g. trailing comma without
        // a following object). Only append to `out` once the entry is complete.
        var entry = std_io.StringBuilder.init(allocator);
        defer entry.deinit();

        entry.writer().writeAll("{\"name\":\"") catch continue;
        writeJsonEscapedString(&entry, name_val.string);
        entry.writer().writeAll("\",\"args\":") catch continue;
        // args may be a JSON string (OpenAI) or a JSON object (Ollama).
        if (args_val == .string) {
            entry.writer().writeByte('"') catch continue;
            writeJsonEscapedString(&entry, args_val.string);
            entry.writer().writeByte('"') catch continue;
        } else if (args_val == .object) {
            // Ollama returns arguments as a JSON object -- serialize it to a string.
            entry.writer().writeByte('"') catch continue;
            var obj_buf = std_io.StringBuilder.init(allocator);
            defer obj_buf.deinit();
            obj_buf.writer().print("{f}", .{std.json.fmt(args_val, .{})}) catch continue;
            writeJsonEscapedString(&entry, obj_buf.items());
            entry.writer().writeByte('"') catch continue;
        } else {
            entry.writer().writeAll("\"{}\"") catch continue;
        }
        entry.writer().writeByte('}') catch continue;

        if (count > 0) out.writer().writeAll(",") catch continue;
        out.writer().writeAll(entry.items()) catch continue;
        count += 1;
    }

    out.writer().writeByte(']') catch {
        out.deinit();
        return "";
    };
    if (count == 0) {
        out.deinit();
        return "";
    }
    return out.toOwnedSlice() catch "";
}

pub fn writeJsonEscapedString(out: *std_io.StringBuilder, s: []const u8) void {
    for (s) |ch| {
        switch (ch) {
            '"' => out.writer().writeAll("\\\"") catch return,
            '\\' => out.writer().writeAll("\\\\") catch return,
            '\n' => out.writer().writeAll("\\n") catch return,
            '\r' => out.writer().writeAll("\\r") catch return,
            '\t' => out.writer().writeAll("\\t") catch return,
            else => out.writer().writeByte(ch) catch return,
        }
    }
}

/// One inbound HTTP response header. Names are lowercased on parse (HTTP
/// headers are case-insensitive; the reference uses `Headers.get`, which
/// lowercases). When produced by `parseCurlHeaderDump`, both `name` and
/// `value` are heap-allocated copies (self-owned) so the pair outlives the
/// raw dump buffer; free the whole slice with `freeHeaderDump`. Test fixtures
/// that construct `HeaderPair` from string literals own nothing.
pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const CurlResponseWithStatus = struct {
    body: []const u8,
    status_code: u16,
    /// Parsed response headers. Defaults to empty so existing callers that
    /// build this struct without header data keep compiling unchanged.
    headers: []const HeaderPair = &.{},
};

pub fn parseCurlResponseWithStatus(raw: []const u8, marker: []const u8) ?CurlResponseWithStatus {
    const marker_idx = std.mem.lastIndexOf(u8, raw, marker) orelse return null;
    const status_slice = std.mem.trim(u8, raw[marker_idx + marker.len ..], " \t\r\n");
    if (status_slice.len == 0) return null;

    const status_code = std.fmt.parseInt(u16, status_slice, 10) catch return null;
    return .{
        .body = raw[0..marker_idx],
        .status_code = status_code,
    };
}

// Bound the number of headers parsed and the length of each value so a
// hostile server cannot blow up memory via a giant or repetitive dump.
const MAX_HEADERS = 200;
const MAX_VALUE_LEN = 8 * 1024;

/// Parse the output of curl's `-D <file>` (dump-header) into a list of
/// `HeaderPair`. The dump is the raw response status line plus `Name: Value`
/// lines, terminated by a blank line. With `-L` (follow redirects) curl emits
/// one such block per response in the redirect chain; we return only the LAST
/// block's headers (the final response the body belongs to).
///
/// Header names are lowercased. Both name and value are heap-allocated copies,
/// so the returned pairs are self-owned and outlive `raw`. Free the whole slice
/// with `freeHeaderDump`.
///
/// A malformed dump (no blank-line terminator, truncated mid-line) yields a
/// best-effort partial slice rather than an error.
pub fn parseCurlHeaderDump(allocator: std.mem.Allocator, raw: []const u8) ![]HeaderPair {
    var pairs: std.ArrayList(HeaderPair) = .empty;
    errdefer freeHeaderDump(allocator, pairs.toOwnedSlice(allocator) catch &.{});

    var line_iter = std.mem.splitScalar(u8, raw, '\n');
    while (line_iter.next()) |raw_line| {
        // Tolerate CRLF: strip a trailing CR left by the \n split.
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        if (line.len == 0) continue; // blank line: block separator, ignore.

        // A status line ("HTTP/1.1 200 OK", "HTTP/2 301") starts a NEW block.
        // Reset so headers from an earlier redirect block are discarded; we
        // only keep the headers that follow the LAST status line (the final
        // response with `-L`). Do NOT reset on the blank line that terminates
        // a block, or the final block's headers would be wiped.
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            freeBlock(allocator, &pairs);
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue; // not a header line
        const name_raw = std.mem.trim(u8, line[0..colon], " \t");
        if (name_raw.len == 0) continue;
        const value_raw = std.mem.trim(u8, line[colon + 1 ..], " \t");

        if (pairs.items.len >= MAX_HEADERS) continue;

        // Names are small: dupe + lowercase. Values are capped in length to
        // bound memory against a hostile server, then duped so the pair is
        // self-owned (the raw dump buffer is freed by the caller right after).
        const name_lower = try std.ascii.allocLowerString(allocator, name_raw);
        errdefer allocator.free(name_lower);
        const value_src = if (value_raw.len > MAX_VALUE_LEN) value_raw[0..MAX_VALUE_LEN] else value_raw;
        const value = try allocator.dupe(u8, value_src);
        errdefer allocator.free(value);

        try pairs.append(allocator, .{ .name = name_lower, .value = value });
    }

    return pairs.toOwnedSlice(allocator);
}

/// Free the pairs accumulated for the prior block (called when a new `HTTP/`
/// status line is seen) and reset the list, retaining capacity.
fn freeBlock(allocator: std.mem.Allocator, pairs: *std.ArrayList(HeaderPair)) void {
    for (pairs.items) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    pairs.clearRetainingCapacity();
}

/// Free a header slice returned by `parseCurlHeaderDump`. Both the name and
/// value strings were heap-allocated. Do NOT call this on `HeaderPair`s built
/// from string literals (e.g. test fixtures).
pub fn freeHeaderDump(allocator: std.mem.Allocator, headers: []const HeaderPair) void {
    for (headers) |h| {
        allocator.free(h.name);
        allocator.free(h.value);
    }
    allocator.free(headers);
}

/// Find a header by its lowercased name. `name_lowercased` must already be
/// lowercase; the stored names are lowercased on parse. Returns the first
/// matching value, or null.
pub fn findHeader(headers: []const HeaderPair, name_lowercased: []const u8) ?[]const u8 {
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, name_lowercased)) return h.value;
    }
    return null;
}

// --- Tests ---

const testing = std.testing;

test "parseSseText parses OpenAI and DeepSeek style deltas" {
    const allocator = testing.allocator;
    const raw =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n" ++
        "data: [DONE]\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("Hello", parsed);
}

test "parseSseText parses Anthropic content delta" {
    const allocator = testing.allocator;
    const raw =
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hi\"}}\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\" there\"}}\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("Hi there", parsed);
}

test "parseSseText returns empty for json payloads without extractable text" {
    const allocator = testing.allocator;
    const raw =
        "data: {\"foo\":\"bar\"}\n" ++
        "data: {\"baz\":1}\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("", parsed);
}

test "parseSseText keeps non-json token streams" {
    const allocator = testing.allocator;
    const raw =
        "data: Hel\n" ++
        "data: lo\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("Hello", parsed);
}

test "parseSseText suppresses reasoning-only chunks" {
    // delta.reasoning_content is the model's internal monologue
    // (kimi-k2.6, DeepSeek-R1, Qwen3-thinking). Surfacing it inline
    // dumped the entire reasoning transcript into the chat window and
    // broke the fullscreen layout. Keep it out of the visible stream;
    // the non-streaming extractor still uses it as a last-resort
    // fallback when content is empty so pure-reasoning turns aren't
    // lost.
    const allocator = testing.allocator;
    const raw =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"The\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\" plan\"}}]}\n" ++
        "data: [DONE]\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("", parsed);
}

test "parseSseText keeps content chunks even when reasoning chunks interleave" {
    const allocator = testing.allocator;
    const raw =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking...\"}}]}\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n" ++
        "data: [DONE]\n";

    const parsed = try parseSseText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("answer", parsed);
}

test "extractFirstText concatenates Anthropic text blocks" {
    const allocator = testing.allocator;
    const raw =
        "{\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"Hello\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"t1\"}," ++
        "{\"type\":\"text\",\"text\":\" world\"}" ++
        "]}";

    const parsed = try extractFirstText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("Hello world", parsed);
}

test "extractFirstText concatenates Gemini text parts" {
    const allocator = testing.allocator;
    const raw =
        "{\"candidates\":[{\"content\":{\"parts\":[" ++
        "{\"text\":\"Hello\"}," ++
        "{\"inlineData\":{\"mimeType\":\"text/plain\"}}," ++
        "{\"text\":\" world\"}" ++
        "]}}]}";

    const parsed = try extractFirstText(allocator, raw);
    defer allocator.free(parsed);

    try testing.expectEqualStrings("Hello world", parsed);
}

test "parse curl response extracts status and body" {
    const raw = "{\"ok\":true}\n__ZCODE_HTTP_STATUS__:200";
    const parsed = parseCurlResponseWithStatus(raw, "\n__ZCODE_HTTP_STATUS__:") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u16, 200), parsed.status_code);
    try testing.expectEqualStrings("{\"ok\":true}", parsed.body);
}

test "parse curl response returns null without status marker" {
    try testing.expect(parseCurlResponseWithStatus("{\"ok\":true}", "\n__ZCODE_HTTP_STATUS__:") == null);
}

test "extractTokenUsage parses OpenAI usage payload" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":45,\"total_tokens\":168}}",
    );
    try testing.expectEqual(@as(?usize, 123), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 45), usage.output_tokens);
}

test "extractTokenUsage parses Anthropic usage payload" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usage\":{\"input_tokens\":77,\"output_tokens\":12}}",
    );
    try testing.expectEqual(@as(?usize, 77), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 12), usage.output_tokens);
    // No cache/web-search fields present -> all null (not zero).
    try testing.expectEqual(@as(?usize, null), usage.cache_read_input_tokens);
    try testing.expectEqual(@as(?usize, null), usage.cache_creation_input_tokens);
    try testing.expectEqual(@as(?usize, null), usage.web_search_requests);
}

test "extractTokenUsage parses Anthropic cache tokens" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usage\":{\"input_tokens\":77,\"output_tokens\":12,\"cache_read_input_tokens\":40,\"cache_creation_input_tokens\":8}}",
    );
    try testing.expectEqual(@as(?usize, 77), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 12), usage.output_tokens);
    try testing.expectEqual(@as(?usize, 40), usage.cache_read_input_tokens);
    try testing.expectEqual(@as(?usize, 8), usage.cache_creation_input_tokens);
    try testing.expectEqual(@as(?usize, null), usage.web_search_requests);
}

test "extractTokenUsage parses Anthropic web_search_requests" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"server_tool_use\":{\"web_search_requests\":2}}}",
    );
    try testing.expectEqual(@as(?usize, 5), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 3), usage.output_tokens);
    try testing.expectEqual(@as(?usize, 2), usage.web_search_requests);
}

test "extractTokenUsage leaves cache fields null for OpenAI payload" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usage\":{\"prompt_tokens\":123,\"completion_tokens\":45,\"total_tokens\":168}}",
    );
    try testing.expectEqual(@as(?usize, 123), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 45), usage.output_tokens);
    try testing.expectEqual(@as(?usize, null), usage.cache_read_input_tokens);
    try testing.expectEqual(@as(?usize, null), usage.cache_creation_input_tokens);
    try testing.expectEqual(@as(?usize, null), usage.web_search_requests);
}

test "extractTokenUsage parses Gemini usage payload" {
    const allocator = testing.allocator;
    const usage = extractTokenUsage(
        allocator,
        "{\"usageMetadata\":{\"promptTokenCount\":200,\"candidatesTokenCount\":31}}",
    );
    try testing.expectEqual(@as(?usize, 200), usage.input_tokens);
    try testing.expectEqual(@as(?usize, 31), usage.output_tokens);
}

test "extractNativeToolCalls parses OpenAI format" {
    const allocator = testing.allocator;
    const raw =
        "{\"choices\":[{\"message\":{\"tool_calls\":[" ++
        "{\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}]}";

    const result = extractNativeToolCalls(allocator, raw);
    defer if (result.len > 0) allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, result, "command") != null);
}

test "extractNativeToolCalls parses Ollama format with object arguments" {
    const allocator = testing.allocator;
    const raw =
        "{\"message\":{\"tool_calls\":[" ++
        "{\"function\":{\"name\":\"Bash\",\"arguments\":{\"command\":\"git log --oneline -3\"}}}]}}";

    const result = extractNativeToolCalls(allocator, raw);
    defer if (result.len > 0) allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Bash") != null);
    try testing.expect(std.mem.indexOf(u8, result, "git log") != null);
}

test "extractNativeToolCalls returns empty for no tool calls" {
    const allocator = testing.allocator;
    const raw = "{\"message\":{\"content\":\"Hello world\"}}";

    const result = extractNativeToolCalls(allocator, raw);
    try testing.expectEqualStrings("", result);
}

test "extractNativeToolCalls parses Anthropic tool_use content blocks" {
    const allocator = testing.allocator;
    const raw = "{\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"I'll read that file.\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_01\",\"name\":\"Read\",\"input\":{\"path\":\"/etc/hosts\"}}" ++
        "]}";

    const result = extractNativeToolCalls(allocator, raw);
    defer if (result.len > 0) allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.indexOf(u8, result, "Read") != null);
    try testing.expect(std.mem.indexOf(u8, result, "path") != null);
    try testing.expect(std.mem.indexOf(u8, result, "/etc/hosts") != null);
}

test "extractNativeToolCalls skips Anthropic text-only content" {
    const allocator = testing.allocator;
    const raw = "{\"content\":[" ++
        "{\"type\":\"text\",\"text\":\"Just a plain reply, no tool use.\"}" ++
        "]}";

    const result = extractNativeToolCalls(allocator, raw);
    // Should fall through to return "" since there's no tool_use block and no OpenAI/Ollama fallback match either.
    try testing.expectEqualStrings("", result);
}

test "parseCurlHeaderDump returns only the final block after a redirect" {
    const allocator = testing.allocator;
    // First block is a 301 redirect (with its own headers we must discard),
    // second block is the final 429 response carrying the headers we care about.
    const raw =
        "HTTP/1.1 301 Moved Permanently\r\n" ++
        "Location: https://api.example.com/v1/messages\r\n" ++
        "Retry-After: 999\r\n" ++
        "\r\n" ++
        "HTTP/2 429 \r\n" ++
        "Content-Type: application/json\r\n" ++
        "Retry-After: 5\r\n" ++
        "X-Should-Retry: true\r\n" ++
        "Anthropic-RateLimit-Unified-Reset: 1717000000\r\n" ++
        "\r\n";

    const headers = try parseCurlHeaderDump(allocator, raw);
    defer freeHeaderDump(allocator, headers);

    // Final block headers are present, lowercased.
    try testing.expectEqualStrings("5", findHeader(headers, "retry-after") orelse "MISSING");
    try testing.expectEqualStrings("true", findHeader(headers, "x-should-retry") orelse "MISSING");
    try testing.expectEqualStrings("1717000000", findHeader(headers, "anthropic-ratelimit-unified-reset") orelse "MISSING");
    try testing.expectEqualStrings("application/json", findHeader(headers, "content-type") orelse "MISSING");

    // The redirect block's Location must NOT survive (only the final block).
    try testing.expect(findHeader(headers, "location") == null);
    // Retry-After must be the FINAL block's value (5), never the redirect's 999.
    try testing.expect(!std.mem.eql(u8, findHeader(headers, "retry-after") orelse "", "999"));
}

test "parseCurlHeaderDump tolerates a malformed truncated dump without crashing" {
    const allocator = testing.allocator;
    // No trailing blank line, truncated mid-stream, mixed LF/CRLF.
    const raw =
        "HTTP/1.1 200 OK\n" ++
        "Content-Type: application/json\n" ++
        "X-Truncated: partial-valu"; // no newline, no blank-line terminator

    const headers = try parseCurlHeaderDump(allocator, raw);
    defer freeHeaderDump(allocator, headers);

    // Best-effort: the well-formed lines parse; nothing crashes.
    try testing.expectEqualStrings("application/json", findHeader(headers, "content-type") orelse "MISSING");
    try testing.expectEqualStrings("partial-valu", findHeader(headers, "x-truncated") orelse "MISSING");
}

test "parseCurlHeaderDump on garbage input returns empty without crashing" {
    const allocator = testing.allocator;
    const raw = "this is not a header dump at all\njust some random text\n";
    const headers = try parseCurlHeaderDump(allocator, raw);
    defer freeHeaderDump(allocator, headers);
    // The second line has no colon, the first does ("dump at all" has none either).
    // "this is not a header dump at all" has no colon -> skipped. Result empty.
    try testing.expectEqual(@as(usize, 0), headers.len);
}

test "findHeader returns null for absent header" {
    const headers = [_]HeaderPair{
        .{ .name = "content-type", .value = "text/plain" },
    };
    try testing.expect(findHeader(&headers, "retry-after") == null);
    try testing.expectEqualStrings("text/plain", findHeader(&headers, "content-type") orelse "MISSING");
}
