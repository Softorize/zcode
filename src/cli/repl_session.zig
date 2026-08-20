const std = @import("std");
const std_io = @import("../core/std_io.zig");
const rt = @import("zcode_runtime");
const rng = @import("../core/rng.zig");
const clock = @import("../core/clock.zig");
const tool_helpers = @import("../tools/helpers.zig");
const repl_markdown_mod = @import("repl_markdown.zig");
const word_slug = @import("../core/word_slug.zig");

// ── Session/plan/brainstorm helpers ──
// Extracted from repl.zig: plan file management, brainstorm-to-planning
// promotion logic, task notification parsing.

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return repl_markdown_mod.containsIgnoreCase(haystack, needle);
}

// ── Brainstorm promotion ──

pub fn shouldPromoteBrainstormToPlanning(line: []const u8) bool {
    const cues = [_][]const u8{
        "approved",
        "approve this",
        "looks good",
        "sounds good",
        "everything else is great",
        "everything else looks good",
        "lets do it",
        "let's do it",
        "go ahead",
        "proceed",
        "plan and execute",
        "planning and execution",
        "execute this",
        "start execution",
        "begin execution",
        "start planning",
        "do planning",
        "do planing",
        "move to planning",
        "create plan",
        "write plan",
    };
    for (cues) |cue| {
        if (containsIgnoreCase(line, cue)) return true;
    }
    return false;
}

pub fn shouldAutoPromoteBrainstormOutputToPlanning(output: []const u8) bool {
    const signal_cues = [_][]const u8{
        "ready for planning",
        "summary ready for planning",
        "ready to begin",
        "implementation plan",
        "execution plan",
        "switch to planning",
    };

    var has_signal = false;
    for (signal_cues) |cue| {
        if (containsIgnoreCase(output, cue)) {
            has_signal = true;
            break;
        }
    }
    if (!has_signal) return false;

    const has_structure =
        containsIgnoreCase(output, "- ") or
        containsIgnoreCase(output, "1.") or
        containsIgnoreCase(output, "**phase ") or
        containsIgnoreCase(output, "## ");

    return has_structure or containsIgnoreCase(output, "task checklist");
}

pub fn buildBrainstormPromotionPrompt(allocator: std.mem.Allocator, user_confirmation: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "The user approved the brainstorm direction (message: \"{s}\").\n" ++
            "Switch into planning output now and produce a concrete markdown implementation plan.\n" ++
            "Required format:\n" ++
            "- Title\n" ++
            "- Goals\n" ++
            "- Assumptions\n" ++
            "- Task checklist using '- [ ]'\n" ++
            "- Risks\n" ++
            "- Definition of done\n" ++
            "Do not call tools in this mode.",
        .{user_confirmation},
    );
}

// ── Plan file management ──

pub fn normalizePlanMarkdown(allocator: std.mem.Allocator, model_output: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, model_output, " \t\r\n");
    if (trimmed.len == 0) {
        return allocator.dupe(
            u8,
            "# Implementation Plan\n\n## Task Checklist\n- [ ] Define scope\n- [ ] Implement core changes\n- [ ] Validate behavior\n- [ ] Ship\n",
        );
    }

    if (std.mem.indexOf(u8, trimmed, "- [ ]") != null) {
        return allocator.dupe(u8, trimmed);
    }

    return std.fmt.allocPrint(
        allocator,
        "# Implementation Plan\n\n## Task Checklist\n- [ ] Break down approved idea into concrete steps\n- [ ] Implement each step\n- [ ] Validate with tests\n- [ ] Prepare release notes\n\n## Draft Notes\n{s}\n",
        .{trimmed},
    );
}

pub fn savePlanFile(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const plans_dir = try tool_helpers.ensureWorkspaceDirPath(allocator, ".", "plans");
    defer allocator.free(plans_dir);

    // Prefer a memorable adjective-verb-noun slug (e.g. "gleaming-brewing-phoenix.md")
    // over the opaque nanosecond stamp previously used. Matches the reference at
    // claude-code-main/src/utils/plans.ts getPlanSlug. We retry up to MAX_SLUG_RETRIES
    // times on collision; if all attempts hit existing files (astronomically unlikely
    // with a ~10M slug space), fall back to the nanosecond stamp so saves never fail.
    const MAX_SLUG_RETRIES = 10;
    var rel_path: ?[]u8 = null;
    defer if (rel_path) |p| allocator.free(p);

    // Seed from the crypto RNG instead of the nanosecond clock. Two
    // concurrent zcode processes that entered this function within the
    // same nanosecond would otherwise produce identical slugs, defeating
    // the retry-on-collision loop below.
    var seed_bytes: [8]u8 = undefined;
    rng.bytes(&seed_bytes);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed_bytes, .little));
    const random = prng.random();

    var retry: usize = 0;
    while (retry < MAX_SLUG_RETRIES) : (retry += 1) {
        const slug = try word_slug.generateSlugAlloc(allocator, random);
        defer allocator.free(slug);
        const plan_name = try std.fmt.allocPrint(allocator, "plans/{s}.md", .{slug});
        defer allocator.free(plan_name);
        const candidate = try tool_helpers.workspaceRelativePathAlloc(allocator, ".", plan_name);

        std.Io.Dir.cwd().access(rt.io, candidate, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                rel_path = candidate;
                break;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        // File exists -- free and retry with a fresh slug.
        allocator.free(candidate);
    }

    if (rel_path == null) {
        const stamp: u64 = @intCast(@max(clock.nowNanos(), 0));
        const plan_name = try std.fmt.allocPrint(allocator, "plans/plan-{d}.md", .{stamp});
        defer allocator.free(plan_name);
        rel_path = try tool_helpers.workspaceRelativePathAlloc(allocator, ".", plan_name);
    }

    var file = try std.Io.Dir.cwd().createFile(rt.io, rel_path.?, .{ .truncate = true });
    defer file.close(rt.io);
    try file.writeStreamingAll(rt.io, text);

    const cwd = try std.process.currentPathAlloc(rt.io, allocator);
    defer allocator.free(cwd);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, rel_path.? });
}

pub fn setOwnedOptional(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    const next = try allocator.dupe(u8, value);
    if (slot.*) |existing| allocator.free(existing);
    slot.* = next;
}

pub fn clearOwnedOptional(allocator: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |existing| allocator.free(existing);
    slot.* = null;
}

pub fn readPlanFileAlloc(allocator: std.mem.Allocator, plan_path: []const u8, max_size: usize) ![]u8 {
    if (std.fs.path.isAbsolute(plan_path)) {
        var file = std.Io.Dir.openFileAbsolute(rt.io, plan_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.PlanFileNotFound,
            else => return err,
        };
        defer file.close(rt.io);
        return blk: {
            const _sz = file.length(rt.io) catch break :blk error.ReadFailed;
            const _max = @min(_sz, max_size);
            const _buf = try allocator.alloc(u8, _max);
            errdefer allocator.free(_buf);
            _ = file.readPositionalAll(rt.io, _buf, 0) catch break :blk error.ReadFailed;
            break :blk _buf;
        };
    }

    return std.Io.Dir.cwd().readFileAlloc(rt.io, plan_path, allocator, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => return error.PlanFileNotFound,
        else => return err,
    };
}

pub fn buildApprovedPlanExecutionPrompt(allocator: std.mem.Allocator, plan_path: []const u8) ![]u8 {
    const plan_data = try readPlanFileAlloc(allocator, plan_path, 512 * 1024);
    defer allocator.free(plan_data);

    return std.fmt.allocPrint(
        allocator,
        "Execute the approved implementation plan now.\nPlan path: {s}\n\n```markdown\n{s}\n```\n" ++
            "Carry out the tasks in order, using tools as needed. If something is blocked, report the blocker and next best action.",
        .{ plan_path, plan_data },
    );
}

// ── Task notification parsing ──

pub fn parseTaskNotificationField(line: []const u8, field: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, line, ';');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = std.mem.trim(u8, part[0..eq], " \t");
        if (!std.mem.eql(u8, key, field)) continue;
        return std.mem.trim(u8, part[eq + 1 ..], " \t");
    }
    return null;
}

pub fn unescapeTaskTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            const n = text[i + 1];
            switch (n) {
                'n' => try out.append('\n'),
                'r' => try out.append('\r'),
                't' => try out.append('\t'),
                '\\' => try out.append('\\'),
                else => {
                    try out.append('\\');
                    try out.append(n);
                },
            }
            i += 1;
            continue;
        }
        try out.append(text[i]);
    }
    return out.toOwnedSlice();
}

pub fn formatTaskNotificationAlloc(allocator: std.mem.Allocator, raw_line: []const u8) ![]u8 {
    const status = parseTaskNotificationField(raw_line, "status") orelse "unknown";
    const msg_enc = parseTaskNotificationField(raw_line, "message") orelse "";
    const msg = try unescapeTaskTextAlloc(allocator, msg_enc);
    defer allocator.free(msg);
    const display_msg = if (msg.len > 0) msg else "(no description)";
    return std.fmt.allocPrint(allocator, "\x1b[2m  \xe2\x9f\xa1 {s}: {s}\x1b[0m", .{ status, display_msg });
}

// ── Tests ──

const testing = std.testing;

test "brainstorm confirmation cues are detected" {
    try testing.expect(shouldPromoteBrainstormToPlanning("Looks good, let's do it"));
    try testing.expect(shouldPromoteBrainstormToPlanning("approved"));
    try testing.expect(shouldPromoteBrainstormToPlanning("dont work in ci cd everything else is great"));
    try testing.expect(!shouldPromoteBrainstormToPlanning("what other options do we have?"));
}

test "brainstorm output auto-promotion to planning is detected" {
    const output =
        "Perfect. Here's the concise summary ready for planning:\n" ++
        "**Implementation Plan**\n" ++
        "1. Phase 1\n" ++
        "2. Phase 2\n" ++
        "Ready to begin?";
    try testing.expect(shouldAutoPromoteBrainstormOutputToPlanning(output));
    try testing.expect(!shouldAutoPromoteBrainstormOutputToPlanning("Let's keep discussing options."));
}

test "normalizePlanMarkdown injects checklist when missing" {
    const normalized = try normalizePlanMarkdown(testing.allocator, "Draft summary without checklist");
    defer testing.allocator.free(normalized);
    try testing.expect(std.mem.indexOf(u8, normalized, "- [ ]") != null);
    try testing.expect(std.mem.startsWith(u8, normalized, "# Implementation Plan"));
}

test "buildApprovedPlanExecutionPrompt returns PlanFileNotFound for missing file" {
    const missing_path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/zcode-missing-plan-{d}.md",
        .{@as(u64, @intCast(@max(clock.nowNanos(), 0)))},
    );
    defer testing.allocator.free(missing_path);

    try testing.expectError(error.PlanFileNotFound, buildApprovedPlanExecutionPrompt(testing.allocator, missing_path));
}

test "parseTaskNotificationField extracts semicolon fields" {
    const line = "ts=1;task_id=task-1;event=started;status=running;message=hello";
    try testing.expectEqualStrings("task-1", parseTaskNotificationField(line, "task_id").?);
    try testing.expectEqualStrings("running", parseTaskNotificationField(line, "status").?);
}
