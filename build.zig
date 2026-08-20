const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version_override = b.option([]const u8, "app_version_override", "Override app version string for release builds");
    const app_version = computeVersionString(b, app_version_override);

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "app_version", app_version);
    // Bake CHANGELOG.md content into the binary so /release-notes
    // shows curated release notes (not git-log commits) even when
    // the installed binary runs outside the source tree. Mirrors the
    // reference's release-notes command which fetches/caches the
    // changelog from a remote URL; zcode embeds at build time so
    // there's no network dependency and no stale cache.
    const changelog_content = readChangelogContent(b);
    build_options.addOption([]const u8, "changelog", changelog_content);

    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/core/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "zcode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Linux needs explicit libc for getpwuid / getpid / localtime_r
            // used by keychain.zig and session_date.zig. macOS links libc
            // implicitly; setting this unconditionally is a no-op there.
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("zcode_runtime", runtime_module);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zcode");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    main_tests.root_module.addOptions("build_options", build_options);
    main_tests.root_module.addImport("zcode_runtime", runtime_module);
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .test_runner = .{ .path = b.path("tools/test_runner.zig"), .mode = .simple },
    });
    integration_tests.root_module.addImport("zcode_runtime", runtime_module);
    const run_integration = b.addRunArtifact(integration_tests);
    run_integration.step.dependOn(b.getInstallStep());
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration.step);
    test_step.dependOn(&run_integration.step);
}

fn readChangelogContent(b: *std.Build) []const u8 {
    // Cap at 1 MiB so a runaway CHANGELOG can't bloat the binary.
    // The file is intended for human-readable notes; anything over
    // that is almost certainly accidental.
    const fallback = "";
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, "CHANGELOG.md", b.allocator, .limited(1 * 1024 * 1024)) catch return fallback;
    return bytes;
}

fn computeVersionString(b: *std.Build, app_version_override: ?[]const u8) []const u8 {
    if (app_version_override) |override| {
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        if (trimmed.len > 0) {
            return b.allocator.dupe(u8, trimmed) catch trimmed;
        }
    }

    const base = readBaseVersionFromManifest(b);

    const git_hash = gitCapture(b, &.{ "git", "rev-parse", "--short=8", "HEAD" }) orelse {
        return base;
    };

    const dirty = isGitDirty(b);
    if (dirty) {
        return std.fmt.allocPrint(b.allocator, "{s}+{s}.dirty", .{ base, git_hash }) catch base;
    }
    return std.fmt.allocPrint(b.allocator, "{s}+{s}", .{ base, git_hash }) catch base;
}

fn readBaseVersionFromManifest(b: *std.Build) []const u8 {
    const fallback = "0.0.0";
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(16 * 1024)) catch return fallback;
    defer b.allocator.free(bytes);

    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return fallback;
    const rest = bytes[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return fallback;
    if (end == 0) return fallback;

    return b.allocator.dupe(u8, rest[0..end]) catch fallback;
}

fn gitCapture(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer b.allocator.free(result.stderr);
    defer b.allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}

fn isGitDirty(b: *std.Build) bool {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "status", "--porcelain", "--untracked-files=normal" },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return false;
    defer b.allocator.free(result.stderr);
    defer b.allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    return std.mem.trim(u8, result.stdout, " \t\r\n").len > 0;
}
