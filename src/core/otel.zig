const std = @import("std");
const std_io = @import("std_io.zig");
const metrics_mod = @import("metrics.zig");

/// Render all global metrics in simplified OTLP JSON format.
pub fn renderOtlpJson(allocator: std.mem.Allocator) ![]u8 {
    const m = metrics_mod.globalMetrics();
    return renderMetricsOtlpJson(allocator, m);
}

/// Render a specific Metrics instance as OTLP JSON.
pub fn renderMetricsOtlpJson(allocator: std.mem.Allocator, m: *const metrics_mod.Metrics) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("{\"resourceMetrics\":[{");
    try w.writeAll("\"resource\":{\"attributes\":[");
    try w.writeAll("{\"key\":\"service.name\",\"value\":{\"stringValue\":\"zcode\"}}");
    try w.writeAll("]},");
    try w.writeAll("\"scopeMetrics\":[{");
    try w.writeAll("\"scope\":{\"name\":\"zcode\"},");
    try w.writeAll("\"metrics\":[");

    var first = true;
    var c_it = m.counters.iterator();
    while (c_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeCounter(w, entry.key_ptr.*, entry.value_ptr.*);
    }
    var g_it = m.gauges.iterator();
    while (g_it.next()) |entry| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeGauge(w, entry.key_ptr.*, entry.value_ptr.*);
    }

    try w.writeAll("]}]}]}");
    return out.toOwnedSlice();
}

fn writeCounter(w: anytype, name: []const u8, value: u64) !void {
    const metric_name = stripLabels(name);
    try w.writeAll("{\"name\":");
    try w.print("{f}", .{std.json.fmt(metric_name, .{})});
    try w.writeAll(",\"sum\":{\"dataPoints\":[{\"asInt\":");
    try w.print("{d}", .{value});
    const labels = extractLabels(name);
    if (labels.len > 0) {
        try w.writeAll(",\"attributes\":[");
        try writeLabelsAsAttributes(w, labels);
        try w.writeByte(']');
    }
    try w.writeAll("}],\"aggregationTemporality\":2,\"isMonotonic\":true}}");
}

fn writeGauge(w: anytype, name: []const u8, value: f64) !void {
    const metric_name = stripLabels(name);
    try w.writeAll("{\"name\":");
    try w.print("{f}", .{std.json.fmt(metric_name, .{})});
    try w.writeAll(",\"gauge\":{\"dataPoints\":[{\"asDouble\":");
    try w.print("{d:.6}", .{value});
    const labels = extractLabels(name);
    if (labels.len > 0) {
        try w.writeAll(",\"attributes\":[");
        try writeLabelsAsAttributes(w, labels);
        try w.writeByte(']');
    }
    try w.writeAll("}]}}");
}

fn stripLabels(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '{')) |idx| return name[0..idx];
    return name;
}

fn extractLabels(name: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, name, '{') orelse return "";
    const close = std.mem.lastIndexOfScalar(u8, name, '}') orelse return "";
    if (close <= open + 1) return "";
    return name[open + 1 .. close];
}

fn writeLabelsAsAttributes(w: anytype, labels: []const u8) !void {
    // Walk `key1="val1",key2="val2",key3=val3` pairs. Handles:
    //   - Quoted values that contain commas ("a, b")
    //   - Backslash-escaped quotes inside quoted values (\")
    //   - Unquoted values
    // The old implementation stopped quoted-value scanning at the first
    // comma, which cut a label like `provider="one,two"` in half and left
    // the remainder as an unparsable tail.
    var first = true;
    var rest = labels;
    while (rest.len > 0) {
        // Trim leading whitespace (benign noise if anyone added spaces).
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
        if (rest.len == 0) break;

        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse break;
        const key = rest[0..eq];
        var pos = eq + 1;

        var val_start: usize = pos;
        var val_end: usize = pos;
        if (pos < rest.len and rest[pos] == '"') {
            // Quoted value: scan until the matching closing quote, honoring
            // backslash escapes.
            val_start = pos + 1;
            var j = val_start;
            while (j < rest.len) : (j += 1) {
                if (rest[j] == '\\' and j + 1 < rest.len) {
                    j += 1;
                    continue;
                }
                if (rest[j] == '"') break;
            }
            if (j >= rest.len) break; // unterminated quote — stop parsing
            val_end = j;
            pos = j + 1;
        } else {
            // Unquoted value: runs to the next comma or end-of-string.
            var j = pos;
            while (j < rest.len and rest[j] != ',') : (j += 1) {}
            val_end = j;
            pos = j;
        }
        const val = rest[val_start..val_end];

        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"key\":");
        try w.print("{f}", .{std.json.fmt(key, .{})});
        try w.writeAll(",\"value\":{\"stringValue\":");
        try w.print("{f}", .{std.json.fmt(val, .{})});
        try w.writeAll("}}");

        if (pos < rest.len and rest[pos] == ',') pos += 1;
        rest = rest[pos..];
    }
}

const testing = std.testing;

test "render empty metrics produces valid JSON" {
    var m = metrics_mod.Metrics.init(testing.allocator);
    defer m.deinit();
    const json = try renderMetricsOtlpJson(testing.allocator, &m);
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(parsed.value.object.get("resourceMetrics") != null);
}

test "render counter appears in OTLP output" {
    var m = metrics_mod.Metrics.init(testing.allocator);
    defer m.deinit();
    m.increment("zcode_test_counter");
    m.increment("zcode_test_counter");
    const json = try renderMetricsOtlpJson(testing.allocator, &m);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"zcode_test_counter\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"asInt\":2") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"isMonotonic\":true") != null);
}

test "render gauge appears in OTLP output" {
    var m = metrics_mod.Metrics.init(testing.allocator);
    defer m.deinit();
    m.setGauge("zcode_test_gauge", 42.5);
    const json = try renderMetricsOtlpJson(testing.allocator, &m);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"zcode_test_gauge\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"asDouble\":42.5") != null);
}

test "OTLP output is valid JSON with mixed metrics" {
    var m = metrics_mod.Metrics.init(testing.allocator);
    defer m.deinit();
    m.increment("zcode_requests_total");
    m.setGauge("zcode_latency_ms", 123.456);
    const json = try renderMetricsOtlpJson(testing.allocator, &m);
    defer testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);
    try testing.expect(std.mem.indexOf(u8, json, "\"service.name\"") != null);
}

test "stripLabels extracts base name" {
    try testing.expectEqualStrings("zcode_requests", stripLabels("zcode_requests{provider=\"openai\"}"));
    try testing.expectEqualStrings("zcode_requests", stripLabels("zcode_requests"));
}

test "extractLabels gets label content" {
    try testing.expectEqualStrings("provider=\"openai\"", extractLabels("zcode_requests{provider=\"openai\"}"));
    try testing.expectEqualStrings("", extractLabels("zcode_requests"));
}

test "writeLabelsAsAttributes handles quoted value containing commas" {
    var buf = std_io.StringBuilder.init(testing.allocator);
    defer buf.deinit();
    // `provider="one,two"` would have split at the inner comma under the
    // old parser and dropped everything after. Both labels should now
    // survive the round trip.
    try writeLabelsAsAttributes(buf.writer(), "provider=\"one,two\",model=\"gpt\"");

    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"one,two\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"model\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items(), "\"gpt\"") != null);
}
