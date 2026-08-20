const std = @import("std");
const testing = std.testing;

const rt = struct {
    var threaded: std.Io.Threaded = undefined;
    var initialized = false;
    fn io() std.Io {
        if (!initialized) {
            threaded = std.Io.Threaded.init(testing.allocator, .{});
            initialized = true;
        }
        return threaded.io();
    }
};

fn realPathAlloc(allocator: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(rt.io(), sub_path, &buf);
    return allocator.dupe(u8, buf[0..n]);
}

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Run zcode as a subprocess and capture output.
fn runZcode(allocator: std.mem.Allocator, args: []const []const u8) !RunResult {
    return runZcodeWithEnvAtPath(allocator, args, &.{}, null);
}

fn runZcodeWithEnv(allocator: std.mem.Allocator, args: []const []const u8, extra_env: []const EnvEntry) !RunResult {
    return runZcodeWithEnvAtPath(allocator, args, extra_env, null);
}

fn runZcodeWithEnvAtPath(allocator: std.mem.Allocator, args: []const []const u8, extra_env: []const EnvEntry, cwd: ?[]const u8) !RunResult {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    const exe_path = try realPathAlloc(allocator, std.Io.Dir.cwd(), "zig-out/bin/zcode");
    defer allocator.free(exe_path);
    try argv.append(exe_path);
    for (args) |arg| try argv.append(arg);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    // The spawned binary runs with an otherwise-empty environment. Default-on
    // session encryption needs a key; on a hermetic runner with no usable
    // keychain (e.g. a headless CI macOS runner) key auto-generation fails
    // closed with InvalidSessionKey. Provide a fixed test key so the env path
    // is taken and the keychain is never touched. extra_env may override it.
    try env_map.put("ZCODE_SESSION_KEY", "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    for (extra_env) |entry| {
        try env_map.put(entry.key, entry.value);
    }

    const result = std.process.run(allocator, rt.io(), .{ .argv = argv.items, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024), .environ_map = &env_map, .cwd = if (cwd) |c| .{ .path = c } else .inherit }) catch |err| {
        return .{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, @errorName(err)),
            .exit_code = 1,
        };
    };

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

fn scriptResponsesJson(allocator: std.mem.Allocator, responses: []const []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(responses, .{})});
}

fn parseJsonOutput(allocator: std.mem.Allocator, stdout: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, stdout, .{});
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingField;
    if (value != .string) return error.InvalidFieldType;
    return value.string;
}

/// Assert zcode exited 0. On failure dump stderr + stdout so CI shows
/// the actual error instead of just `expected 0, found 1`.
fn expectExitZero(result: RunResult) !void {
    if (result.exit_code != 0) {
        std.debug.print(
            "\n--- zcode exit_code={d}\n--- stderr ({d} bytes) ---\n{s}\n--- stdout ({d} bytes) ---\n{s}\n--- end ---\n",
            .{ result.exit_code, result.stderr.len, result.stderr, result.stdout.len, result.stdout },
        );
    }
    try testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "zcode version outputs version string" {
    const result = try runZcode(testing.allocator, &.{"version"});
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(std.mem.startsWith(u8, result.stdout, "zcode "));
    try testing.expect(result.exit_code == 0);
}

test "zcode help exits cleanly" {
    const result = try runZcode(testing.allocator, &.{"help"});
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "zcode") != null);
    try testing.expect(result.exit_code == 0);
}

test "zcode policy show outputs default policy" {
    const result = try runZcode(testing.allocator, &.{ "policy", "show" });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // Policy show should output at least the default_approval_mode.
    try testing.expect(std.mem.indexOf(u8, result.stdout, "default_approval_mode") != null or result.exit_code == 0);
}

test "zcode session list outputs without error" {
    const result = try runZcode(testing.allocator, &.{ "session", "list" });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // May be empty or have sessions - either is fine, just no crash.
    try testing.expect(result.exit_code == 0);
}

test "mock scripted schema wrapper executes real shell tool call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);

    const responses = [_][]const u8{
        "I can check that for you. Would you like me to proceed?",
        "```tool_call\n{\n  \"tool\": \"shell\",\n  \"schema\": {\n    \"command\": \"printf 'ollama version is 0.15.4\\nWarning: client version is 0.19.0\\n'\",\n    \"timeout_seconds\": 10\n  }\n}\n```",
        "{\"assistant\":\"Configured the Ollama compatibility check and verified the installed version details.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnv(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "--sandbox",
        // This case verifies schema-wrapper parsing and shell execution. Keep
        // sandbox behavior out of scope so Linux CI does not depend on nested
        // bubblewrap support from the hosted runner.
        "danger-full-access",
        "exec",
        "--json",
        "configure my local 32 billion parameter with olama on my spark server",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "Configured the Ollama compatibility check") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 1), tool_calls.array.items.len);
    const first_call = tool_calls.array.items[0].object;
    try testing.expectEqualStrings("shell", try objectString(first_call, "name"));
    try testing.expectEqualStrings(
        "command=printf 'ollama version is 0.15.4\n" ++
            "Warning: client version is 0.19.0\n" ++
            "';timeout_seconds=10",
        try objectString(first_call, "args"),
    );
    try testing.expect(std.mem.indexOf(u8, try objectString(first_call, "output"), "ollama version is 0.15.4") != null);
}

test "mock scripted timed progress auto-continues with status check" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);

    const responses = [_][]const u8{
        "I'll begin by pulling the model. Would you like me to proceed?",
        "```tool_call\n{\n  \"tool\": \"shell\",\n  \"schema\": {\n    \"command\": \"printf 'pulling manifest\\npulling 0bd51f8f0c97:  30%%  11 GB/39 GB\\n[timeout=60s]\\n'\",\n    \"timeout_seconds\": 60\n  }\n}\n```",
        "The process of pulling the 300 billion parameter model (`llama3:70b`) via Ollama is taking a long time, and the download is only at 30% completion. Since the command timed out after 60 seconds, we need to either:\n\n1. **Increase the timeout** to allow the download to complete.\n2. **Check if the model is already partially downloaded** and resume the process.\n\nWould you like to increase the timeout and try again, or check the status of the download?",
        "```tool_call\n{\n  \"tool\": \"shell\",\n  \"schema\": {\n    \"command\": \"printf 'NAME               ID              SIZE      MODIFIED\\nllama3:70b         abc123          39 GB     just now\\n'\",\n    \"timeout_seconds\": 10\n  }\n}\n```",
        "{\"assistant\":\"Checked model status after the timed download and verified that llama3:70b is now visible in the local model list.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnv(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "--sandbox",
        "read-only",
        "exec",
        "--json",
        "pull llama3:70b with ollama and continue autonomously until the model is available",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const response = try objectString(obj, "response");
    try testing.expect(std.mem.indexOf(u8, response, "Checked model status after the timed download") != null);
    try testing.expect(std.mem.indexOf(u8, response, "Would you like to increase the timeout") == null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), tool_calls.array.items.len);
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[0].object, "output"), "[timeout=60s]") != null);
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[1].object, "output"), "llama3:70b") != null);
}

test "mock scripted read-only mutation ends with final no action blocker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);

    const responses = [_][]const u8{
        "To configure your local 32 billion parameter model with Ollama, I should first check the current installation. Would you like me to do that?",
        "```tool_call\n{\n  \"tool\": \"shell\",\n  \"schema\": {\n    \"command\": \"printf 'ollama version is 0.15.4\\nWarning: client version is 0.19.0\\n'\",\n    \"timeout_seconds\": 10\n  }\n}\n```",
        "The Ollama client is installed, but the server is older than the client. We should update Ollama. Would you like me to proceed with the update?",
        "```tool_call\n{\n  \"tool\": \"shell\",\n  \"schema\": {\n    \"command\": \"curl -fsSL https://ollama.com/install.sh | sh\",\n    \"timeout_seconds\": 300\n  }\n}\n```",
        "It seems that the environment is read-only, and I cannot execute commands to update or install software directly. However, you can run:\n\n```bash\ncurl -fsSL https://ollama.com/install.sh | sh\n```\n\nThen verify with:\n\n```bash\nollama --version\n```",
        "{\"assistant\":\"FINAL_NO_ACTION\\nReason: The environment is read-only, so the required Ollama update and model installation commands cannot be executed here.\\nCompleted Result: I verified the current Ollama version and stopped once the sandbox blocked the required mutation.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnv(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "--sandbox",
        "read-only",
        "exec",
        "--json",
        "configure my local 32 billion parameter with olama on my spark server",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const response = try objectString(obj, "response");
    try testing.expect(std.mem.indexOf(u8, response, "FINAL_NO_ACTION") != null);
    try testing.expect(std.mem.indexOf(u8, response, "read-only") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), tool_calls.array.items.len);
    try testing.expectEqualStrings("blocked", try objectString(tool_calls.array.items[1].object, "approval_state"));
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[1].object, "output"), "read-only sandbox blocks mutating shell commands") != null);
}

test "mock scripted todo tools persist session checklist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Tracking the work before I inspect files.\",\"tool_calls\":[{\"name\":\"TodoWrite\",\"args\":{\"items\":[{\"content\":\"Inspect runtime loop\",\"status\":\"in_progress\"},{\"content\":\"Add regression tests\",\"status\":\"pending\"},{\"content\":\"Ship release notes\",\"status\":\"completed\"}]}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Reading the current checklist back.\",\"tool_calls\":[{\"name\":\"TodoRead\",\"args\":{}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Checklist initialized and persisted for the session.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "implement a runtime hardening pass and keep a todo checklist",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), tool_calls.array.items.len);
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[0].object, "output"), "open_count=2") != null);
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[1].object, "output"), "Inspect runtime loop") != null);
}

test "mock scripted AgentRun supports builtin specialist agent selection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Delegating focused discovery to the explore specialist.\",\"tool_calls\":[{\"name\":\"AgentRun\",\"args\":{\"agent\":\"explore\",\"prompt\":\"Inspect the repo and identify the main runtime loop entrypoint.\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"The runtime loop entrypoint is AgentRuntime.handlePromptDetailedWithModeAndReporter in src/agent_runtime.zig, which coordinates prompt construction, model calls, and tool execution.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
        "{\"assistant\":\"Used the explore specialist and confirmed the runtime loop entrypoint in src/agent_runtime.zig.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnv(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "investigate the repo and find the main runtime loop",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "explore specialist") != null);
    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 1), tool_calls.array.items.len);
    try testing.expectEqualStrings("AgentRun", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[0].object, "output"), "src/agent_runtime.zig") != null);
}

test "mock scripted mutation requires verification before final response" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Updating the file now.\",\"tool_calls\":[{\"name\":\"Write\",\"args\":{\"path\":\"notes.txt\",\"content\":\"hardening complete\\n\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Updated notes.txt with the requested content.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
        "{\"assistant\":\"Running a verification command before I finish.\",\"tool_calls\":[{\"name\":\"RunTests\",\"args\":{\"command\":\"printf 'verification passed\\\\n'\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Updated notes.txt and verified the result with a follow-up command.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "implement the change in notes.txt and make sure it is verified before you stop",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "verified the result") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 2), tool_calls.array.items.len);
    try testing.expectEqualStrings("Write", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expectEqualStrings("RunTests", try objectString(tool_calls.array.items[1].object, "name"));
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[1].object, "output"), "verification passed") != null);
}

test "mock scripted repeated reads trigger action-only stall guard" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "workspace/a.txt", .data = "first context\n" });
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "workspace/b.txt", .data = "second context\n" });
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "workspace/c.txt", .data = "third context\n" });
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Reading the first file.\",\"tool_calls\":[{\"name\":\"Read\",\"args\":{\"path\":\"a.txt\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Reading the second file.\",\"tool_calls\":[{\"name\":\"Read\",\"args\":{\"path\":\"b.txt\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Trying one more read instead of acting.\",\"tool_calls\":[{\"name\":\"Read\",\"args\":{\"path\":\"c.txt\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Writing the requested output now.\",\"tool_calls\":[{\"name\":\"Write\",\"args\":{\"path\":\"output.txt\",\"content\":\"implemented after stall guard\\n\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Implemented output.txt after the read-only stall guard forced action.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "implement the requested change in output.txt",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "stall guard forced action") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 3), tool_calls.array.items.len);
    try testing.expectEqualStrings("Read", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expectEqualStrings("Read", try objectString(tool_calls.array.items[1].object, "name"));
    try testing.expectEqualStrings("Write", try objectString(tool_calls.array.items[2].object, "name"));

    const written = try tmp.dir.readFileAlloc(rt.io(), "workspace/output.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("implemented after stall guard", written);
}

test "mock scripted repeated next-step text after edit forces tool call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const repeated_next_step = "Confirmed crypto-js is unused - no require or import references anywhere in the codebase. The dependency has been removed from package.json. Now let me update package-lock.json to match.";
    const responses = [_][]const u8{
        "{\"assistant\":\"Removing the package dependency now.\",\"tool_calls\":[{\"name\":\"Write\",\"args\":{\"path\":\"package.json\",\"content\":\"{\\\"dependencies\\\":{}}\"}}],\"control\":{\"continue\":true}}",
        repeated_next_step,
        repeated_next_step,
        "{\"assistant\":\"Updating the lockfile now.\",\"tool_calls\":[{\"name\":\"Write\",\"args\":{\"path\":\"package-lock.json\",\"content\":\"{\\\"packages\\\":{}}\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Updated both package files.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
        "{\"assistant\":\"Running verification.\",\"tool_calls\":[{\"name\":\"RunTests\",\"args\":{\"command\":\"printf 'lockfile ok\\\\n'\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Removed crypto-js from package.json, updated package-lock.json, and verified the lockfile update.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "remove crypto-js and keep the lockfile consistent",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "updated package-lock.json") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 3), tool_calls.array.items.len);
    try testing.expectEqualStrings("Write", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expectEqualStrings("Write", try objectString(tool_calls.array.items[1].object, "name"));
    try testing.expectEqualStrings("RunTests", try objectString(tool_calls.array.items[2].object, "name"));

    const lockfile = try tmp.dir.readFileAlloc(rt.io(), "workspace/package-lock.json", testing.allocator, .limited(1024));
    defer testing.allocator.free(lockfile);
    try testing.expectEqualStrings("{\"packages\":{}}", lockfile);
}

test "mock scripted exit_plan_mode surfaces plan markdown as final text" {
    // Regression test for the Claude-Code-alignment commits 0.11.22-0.11.23:
    // the agent loop's pending_plan_markdown path must capture the `plan`
    // arg from an exit_plan_mode tool call and surface it as final_text.
    // Before the rewrite, the REPL inferred "plan ready" from heuristic
    // markdown shape, which fired on stall messages too. Now plan
    // approval is gated on an explicit tool call.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    // Two-turn script: enter planning, then call exit_plan_mode with a
    // markdown plan as the arg.
    const responses = [_][]const u8{
        "{\"assistant\":\"Switching to planning mode.\",\"tool_calls\":[{\"name\":\"enter_plan_mode\",\"args\":{}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Plan ready.\",\"tool_calls\":[{\"name\":\"exit_plan_mode\",\"args\":{\"plan\":\"# Refactor crypto-js out\"}}],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "exec",
        "--json",
        "investigate crypto-js usage and produce a removal plan",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const response = try objectString(obj, "response");
    // Final text must be the plan markdown the tool received, NOT the
    // tool acknowledgment string from handleModeControlTool.
    try testing.expect(std.mem.indexOf(u8, response, "# Refactor crypto-js out") != null);

    // Both mode-control tool calls should appear in the trace.
    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expect(tool_calls.array.items.len >= 2);
    try testing.expectEqualStrings("enter_plan_mode", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expectEqualStrings("exit_plan_mode", try objectString(tool_calls.array.items[1].object, "name"));
}

test "mock scripted exit_plan_mode outside planning is refused" {
    // Safety contract: exit_plan_mode is only valid in planning mode.
    // Called from execution mode it must NOT surface a plan markdown
    // as final_text; the runtime returns an error string and the
    // turn continues normally. This is the Claude-Code-parity guard
    // at handleModeControlTool's "ExitPlanMode is only valid while
    // planning" branch.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Calling exit_plan_mode from exec.\",\"tool_calls\":[{\"name\":\"exit_plan_mode\",\"args\":{\"plan\":\"# Spurious plan\"}}],\"control\":{\"continue\":true}}",
        "{\"assistant\":\"Task done normally.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider", "mock",   "--model",      "mock-agent",
        "exec",       "--json", "do something",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    const response = try objectString(obj, "response");
    // The spurious plan must NOT become the final response.
    try testing.expect(std.mem.indexOf(u8, response, "# Spurious plan") == null);
    // The model's normal second-turn assistant_text should win.
    try testing.expect(std.mem.indexOf(u8, response, "Task done normally") != null);

    // The exit_plan_mode trace should still appear, with the rejection
    // message in its output.
    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expect(tool_calls.array.items.len >= 1);
    const first_tool = tool_calls.array.items[0].object;
    try testing.expectEqualStrings("exit_plan_mode", try objectString(first_tool, "name"));
    try testing.expect(std.mem.indexOf(u8, try objectString(first_tool, "output"), "only valid while planning") != null);
}

test "mock scripted bare shell prompt dispatches Bash before model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(rt.io(), "workspace");
    const home_dir = try realPathAlloc(testing.allocator, tmp.dir, ".");
    defer testing.allocator.free(home_dir);
    const workspace_dir = try realPathAlloc(testing.allocator, tmp.dir, "workspace");
    defer testing.allocator.free(workspace_dir);

    const responses = [_][]const u8{
        "{\"assistant\":\"Ran pwd directly and summarized the current working directory.\",\"tool_calls\":[],\"control\":{\"continue\":false}}",
    };
    const scripted = try scriptResponsesJson(testing.allocator, responses[0..]);
    defer testing.allocator.free(scripted);

    const result = try runZcodeWithEnvAtPath(testing.allocator, &.{
        "--provider",
        "mock",
        "--model",
        "mock-agent",
        "--sandbox",
        "danger-full-access",
        "exec",
        "--json",
        "pwd",
    }, &.{
        .{ .key = "HOME", .value = home_dir },
        .{ .key = "ZCODE_MOCK_RESPONSES", .value = scripted },
    }, workspace_dir);
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(std.mem.indexOf(u8, try objectString(obj, "response"), "Ran pwd directly") != null);

    const tool_calls = obj.get("tool_calls") orelse return error.MissingField;
    try testing.expectEqual(@as(usize, 1), tool_calls.array.items.len);
    try testing.expectEqualStrings("Bash", try objectString(tool_calls.array.items[0].object, "name"));
    try testing.expectEqualStrings("pwd", try objectString(tool_calls.array.items[0].object, "args"));
    try testing.expect(std.mem.indexOf(u8, try objectString(tool_calls.array.items[0].object, "output"), workspace_dir) != null);
}

test "prompt inspect summary reports skipped preprocessor and omits packets" {
    const result = try runZcode(testing.allocator, &.{ "prompt", "inspect", "--json", "--summary", "fix", "tests" });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try expectExitZero(result);

    var parsed = try parseJsonOutput(testing.allocator, result.stdout);
    defer parsed.deinit();

    const obj = parsed.value.object;
    try testing.expect(obj.get("summary").?.bool);
    try testing.expect(obj.get("preprocessor_skipped").?.bool);
    try testing.expect(obj.get("system_prompt") == null);
    try testing.expect(obj.get("user_prompt_packet") == null);
}

test "prompt inspect exits cleanly when stdout pipe closes" {
    const exe_path = try realPathAlloc(testing.allocator, std.Io.Dir.cwd(), "zig-out/bin/zcode");
    defer testing.allocator.free(exe_path);

    const result = std.process.run(testing.allocator, rt.io(), .{
        // Provide a fixed session key inline: this test runs the binary
        // through bash (not the runZcode* harness), so it would otherwise
        // inherit an environment with no key and, on a headless CI runner
        // with no usable keychain, fail closed at store init with
        // InvalidSessionKey before ever reaching the pipe.
        .argv = &.{ "/bin/bash", "-o", "pipefail", "-c", "ZCODE_SESSION_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff \"$1\" prompt inspect --json fix tests | head -c 80", "bash", exe_path },
        .stdout_limit = .limited(1 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
    }) catch |err| {
        return err;
    };
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expect(result.stdout.len > 0);
}
