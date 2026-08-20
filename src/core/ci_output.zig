const std = @import("std");
const std_io = @import("std_io.zig");

pub const ToolCall = struct {
    name: []const u8,
    args: []const u8,
    risk: []const u8,
    approval_state: []const u8,
    executed: bool,
    duration_ms: i64,
    output: []const u8,
};

pub fn encodeExecJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    provider: []const u8,
    model: []const u8,
    rounds: usize,
    compaction_applied: bool,
    strict_violation: bool,
    response: []const u8,
    tool_calls: []const ToolCall,
) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    defer out.deinit();
    try out.writer().print("{f}", .{std.json.fmt(.{
        .session_id = session_id,
        .provider = provider,
        .model = model,
        .rounds = rounds,
        .compaction_applied = compaction_applied,
        .strict_violation = strict_violation,
        .response = response,
        .tool_calls = tool_calls,
    }, .{})});
    try out.append('\n');
    return out.toOwnedSlice();
}

const testing = std.testing;

test "encode exec json contract keys" {
    const allocator = testing.allocator;
    const payload = try encodeExecJson(
        allocator,
        "s1",
        "mock",
        "mock-agent",
        1,
        false,
        false,
        "ok",
        &[_]ToolCall{
            .{
                .name = "git_status",
                .args = "",
                .risk = "LOW",
                .approval_state = "auto_approved",
                .executed = true,
                .duration_ms = 3,
                .output = "clean",
            },
        },
    );
    defer allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("session_id") != null);
    try testing.expect(parsed.value.object.get("provider") != null);
    try testing.expect(parsed.value.object.get("model") != null);
    try testing.expect(parsed.value.object.get("rounds") != null);
    try testing.expect(parsed.value.object.get("compaction_applied") != null);
    try testing.expect(parsed.value.object.get("response") != null);
    try testing.expect(parsed.value.object.get("tool_calls") != null);
}
