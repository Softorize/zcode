const std = @import("std");
const rt = @import("zcode_runtime");
const shell_tool = @import("shell.zig");

pub fn runTests(allocator: std.mem.Allocator, cwd: []const u8, command: ?[]const u8) ![]u8 {
    const cmd = if (command) |c|
        if (std.mem.trim(u8, c, " \t").len > 0) c else detectDefaultTestCommand(cwd)
    else
        detectDefaultTestCommand(cwd);

    if (cmd.len == 0) {
        return allocator.dupe(u8, "run_tests failed: no test command configured and no known project type detected");
    }
    return shell_tool.run(allocator, cwd, cmd, 600, "workspace-write");
}

fn detectDefaultTestCommand(cwd: []const u8) []const u8 {
    if (hasPath(cwd, "build.zig")) return "zig build test";
    if (hasPath(cwd, "bun.lockb") or hasPath(cwd, "bun.lock")) return "bun test";
    if (hasPath(cwd, "pnpm-lock.yaml")) return "pnpm test";
    if (hasPath(cwd, "yarn.lock")) return "yarn test";
    if (hasPath(cwd, "package.json")) return "npm test";
    if (hasPath(cwd, "poetry.lock")) return "poetry run pytest";
    if (hasPath(cwd, "pytest.ini")) return "pytest";
    if (hasPath(cwd, "pyproject.toml")) return "pytest";
    if (hasPath(cwd, "deno.json") or hasPath(cwd, "deno.jsonc")) return "deno test";
    if (hasPath(cwd, "Cargo.toml")) return "cargo test";
    if (hasPath(cwd, "go.mod")) return "go test ./...";
    if (hasPath(cwd, "gradlew")) return "./gradlew test";
    if (hasPath(cwd, "build.gradle") or hasPath(cwd, "build.gradle.kts")) return "gradle test";
    if (hasPath(cwd, "pom.xml")) return "mvn test";
    if (hasPath(cwd, "composer.json")) return "composer test";
    if (hasPath(cwd, "Gemfile")) return "bundle exec rake test";
    if (hasPath(cwd, "mix.exs")) return "mix test";
    if (hasPath(cwd, "Makefile") and makefileHasTestTarget(cwd)) return "make test";
    return "";
}

fn hasPath(cwd: []const u8, rel: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const abs = std.fs.path.join(fba.allocator(), &.{ cwd, rel }) catch return false;
    if (std.Io.Dir.cwd().access(rt.io, abs, .{})) |_| {
        return true;
    } else |_| {
        return false;
    }
}

/// Return true if `cwd/Makefile` declares a `test:` target. The previous
/// heuristic just checked whether a file or directory named "test" existed
/// at the workspace root, which matches most C/Go/Rust repos (they all have
/// a test/ directory) and incorrectly selects `make test` even when the
/// Makefile has no test target, making `run_tests` fail with a confusing
/// "make: *** No rule to make target 'test'" error.
fn makefileHasTestTarget(cwd: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const abs = std.fs.path.join(fba.allocator(), &.{ cwd, "Makefile" }) catch return false;

    var content_buf: [64 * 1024]u8 = undefined;
    const file = std.Io.Dir.cwd().openFile(rt.io, abs, .{}) catch return false;
    defer file.close(rt.io);
    const read = file.readPositionalAll(rt.io, &content_buf, 0) catch return false;
    const content = content_buf[0..read];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        // Skip comments and blanks. Only real rule lines (no leading tab)
        // can declare a target, and a target line has the form `name:` or
        // `name: deps`.
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == 0) continue;
        if (line.len > 0 and line[0] == '\t') continue;
        if (trimmed[0] == '#') continue;

        // Split on the first colon; left side must contain "test" as one of
        // the targets on this rule line (targets can be space-separated).
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        if (colon == 0) continue;
        // Guard against `:=` assignment lines (GNU make variables).
        if (colon + 1 < trimmed.len and trimmed[colon + 1] == '=') continue;
        const targets = trimmed[0..colon];
        var it = std.mem.tokenizeAny(u8, targets, " \t");
        while (it.next()) |target| {
            if (std.mem.eql(u8, target, "test")) return true;
        }
    }
    return false;
}

const testing = std.testing;

test "detectDefaultTestCommand prefers package-manager specific runners" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "package.json", .data = "{ }\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "pnpm-lock.yaml", .data = "lockfileVersion: 9\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expectEqualStrings("pnpm test", detectDefaultTestCommand(cwd));
}

test "detectDefaultTestCommand detects bun before generic npm" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "package.json", .data = "{ }\n" });
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "bun.lock", .data = "{}\n" });
    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expectEqualStrings("bun test", detectDefaultTestCommand(cwd));
}

test "makefileHasTestTarget only matches a real rule" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Case 1: Makefile has a test/ directory but no `test:` target.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "Makefile",
        .data = "build:\n\tgcc main.c\n\nclean:\n\trm *.o\n",
    });
    try tmp.dir.createDirPath(rt.io, "test");

    const cwd = try @import("../core/test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!makefileHasTestTarget(cwd));

    // Case 2: Makefile has a real `test:` rule.
    try tmp.dir.writeFile(rt.io, .{
        .sub_path = "Makefile",
        .data = "build:\n\tgcc main.c\n\ntest: build\n\t./runtests.sh\n",
    });
    try testing.expect(makefileHasTestTarget(cwd));
}
