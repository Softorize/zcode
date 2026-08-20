//! Task 3 (PRD #534, hooks-01) integration tests: non-tool lifecycle events
//! actually fire through `hooks.runEvent`. Each test writes a hermetic
//! user-scope `settings.json` (under a tmp HOME) defining a lifecycle hook and
//! drives `runEvent` directly, asserting the stdout-JSON-contract outcome:
//!   - SessionStart additionalContext is surfaced as the hook output.
//!   - UserPromptSubmit exiting 2 with a reason blocks with that reason.
//!   - Stop exiting 2 blocks (the caller interprets this as "force continue").
//!
//! These mirror the synchronous settings.json path the agent loop uses at each
//! lifecycle point; the hermetic-HOME pattern matches the Task 4 tests in
//! `hooks.zig` so the user settings source resolves into a tree we control.

const std = @import("std");
const rt = @import("zcode_runtime");
const hooks = @import("hooks.zig");
const paths = @import("paths.zig");
const env = @import("env.zig");
const test_helpers = @import("test_helpers.zig");

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Override HOME (and clear XDG_CONFIG_HOME) so the user settings source
/// resolves under `home`. Creates `{home}/.zcode` so paths.resolve pins
/// zcode_home there. Restores the prior values on deinit. Replicated from the
/// Task 4 tests in hooks.zig (that helper is module-private).
const HomeOverride = struct {
    prev_home: ?[]u8,
    prev_xdg: ?[]u8,
    allocator: std.mem.Allocator,

    fn install(allocator: std.mem.Allocator, home: []const u8) !HomeOverride {
        const prev_home = if (env.getOwned(allocator, "HOME")) |v| v else |_| null;
        const prev_xdg = if (env.getOwned(allocator, "XDG_CONFIG_HOME")) |v| v else |_| null;

        const home_z = try allocator.dupeZ(u8, home);
        defer allocator.free(home_z);
        _ = setenv("HOME", home_z, 1);
        _ = unsetenv("XDG_CONFIG_HOME");

        const zcode_home = try std.fs.path.join(allocator, &.{ home, ".zcode" });
        defer allocator.free(zcode_home);
        try paths.ensureDir(zcode_home);

        return .{ .prev_home = prev_home, .prev_xdg = prev_xdg, .allocator = allocator };
    }

    fn deinit(self: *HomeOverride) void {
        if (self.prev_home) |h| {
            const z = self.allocator.dupeZ(u8, h) catch return;
            defer self.allocator.free(z);
            _ = setenv("HOME", z, 1);
            self.allocator.free(h);
        } else {
            _ = unsetenv("HOME");
        }
        if (self.prev_xdg) |x| {
            const z = self.allocator.dupeZ(u8, x) catch return;
            defer self.allocator.free(z);
            _ = setenv("XDG_CONFIG_HOME", z, 1);
            self.allocator.free(x);
        } else {
            _ = unsetenv("XDG_CONFIG_HOME");
        }
    }
};

fn writeFileMakingDirs(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        dir.createDirPath(rt.io, parent) catch {};
    }
    try dir.writeFile(rt.io, .{ .sub_path = sub_path, .data = data });
}

test "Task 3: SessionStart hook surfaces additionalContext" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // User-scope SessionStart hook (no trust gate) echoing additionalContext.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"hookSpecificOutput\":{\"additionalContext\":\"INJECTED\"}}'"}]}]}}
    );

    var result = try hooks.runEvent(alloc, .{ .event = .session_start, .cwd = cwd, .source = "startup" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(!result.blocked);
    try testing.expectEqualStrings("INJECTED", result.output);
}

test "Task 3: UserPromptSubmit hook exiting 2 blocks with reason" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Hook prints the reason on stdout then exits 2 -> blocking. The reason
    // surfaces as the hook output (the command path captures stdout).
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"echo BLOCKED_REASON; exit 2"}]}]}}
    );

    var result = try hooks.runEvent(alloc, .{ .event = .user_prompt_submit, .cwd = cwd, .prompt = "hello" });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    try testing.expect(result.blocked);
    try testing.expect(std.mem.indexOf(u8, result.output, "BLOCKED_REASON") != null);
}

test "Task 3: Stop hook exiting 2 blocks (force-continue signal)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo keep-going; exit 2"}]}]}}
    );

    var result = try hooks.runEvent(alloc, .{ .event = .stop, .cwd = cwd });
    defer result.deinit(alloc);
    try testing.expect(result.ran);
    // Stop is blocking-capable: exit 2 is interpreted as a block which the agent
    // loop treats as "force one continuation".
    try testing.expect(result.blocked);
    try testing.expect(std.mem.indexOf(u8, result.output, "keep-going") != null);
}

test "background-svc-09: Notification hook runs and never blocks (exit 2)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // A Notification hook that drops a sentinel and exits 2. Notification is
    // observability-only (not blocking-capable), so exit 2 must NOT block --
    // the notification still emits. The sentinel proves the hook ran.
    const sentinel = try std.fs.path.join(alloc, &.{ cwd, "notified.txt" });
    defer alloc.free(sentinel);
    const cmd = try std.fmt.allocPrint(alloc,
        \\{{"hooks":{{"Notification":[{{"matcher":"*","hooks":[{{"type":"command","command":"touch '{s}'; exit 2"}}]}}]}}}}
    , .{sentinel});
    defer alloc.free(cmd);
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", cmd);

    var result = try hooks.runEvent(alloc, .{
        .event = .notification,
        .cwd = cwd,
        .message = "zcode ready",
        .title = "zcode",
    });
    defer result.deinit(alloc);

    try testing.expect(result.ran);
    // exit 2 on a non-blocking-capable event is a user_error, not a block.
    try testing.expect(!result.blocked);
    // The hook actually executed: the sentinel file exists.
    std.Io.Dir.cwd().access(rt.io, sentinel, .{}) catch |err| {
        std.debug.print("Notification hook sentinel missing: {s} ({any})\n", .{ sentinel, err });
        return error.NotificationHookDidNotRun;
    };
}

test "background-svc-09: Notification matcher selects on message field" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // The Notification matcher tests against the message field (hooks.zig:115)
    // via a glob (hook_matcher.matchesField -> globMatch). A "*ready*" matcher
    // matches "zcode ready" but not "working".
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"Notification":[{"matcher":"*ready*","hooks":[{"type":"command","command":"echo MATCHED_NOTIF"}]}]}}
    );

    var miss = try hooks.runEvent(alloc, .{ .event = .notification, .cwd = cwd, .message = "working" });
    defer miss.deinit(alloc);
    try testing.expect(!miss.ran);

    var hit = try hooks.runEvent(alloc, .{ .event = .notification, .cwd = cwd, .message = "zcode ready" });
    defer hit.deinit(alloc);
    try testing.expect(hit.ran);
    try testing.expect(std.mem.indexOf(u8, hit.output, "MATCHED_NOTIF") != null);
}

test "Task 3: SessionStart matcher selects on source field" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try test_helpers.tmpDirCwd(alloc, &tmp);
    defer alloc.free(root);

    var home_ov = try HomeOverride.install(alloc, root);
    defer home_ov.deinit();

    try tmp.dir.createDirPath(rt.io, "proj");
    const cwd = try test_helpers.tmpDirPath(alloc, &tmp, "proj");
    defer alloc.free(cwd);

    // Matcher is the literal source "resume"; a "startup" source must not match.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"SessionStart":[{"matcher":"resume","hooks":[{"type":"command","command":"echo RESUME_ONLY"}]}]}}
    );

    var miss = try hooks.runEvent(alloc, .{ .event = .session_start, .cwd = cwd, .source = "startup" });
    defer miss.deinit(alloc);
    try testing.expect(!miss.ran);

    var hit = try hooks.runEvent(alloc, .{ .event = .session_start, .cwd = cwd, .source = "resume" });
    defer hit.deinit(alloc);
    try testing.expect(hit.ran);
    try testing.expect(std.mem.indexOf(u8, hit.output, "RESUME_ONLY") != null);
}
