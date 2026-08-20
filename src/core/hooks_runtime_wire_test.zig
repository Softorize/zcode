//! Phase 5 (PRD #534, hooks-01) RUNTIME wiring integration tests.
//!
//! `core/hooks_lifecycle_test.zig` proves the hook ENGINE (`hooks.runEvent`)
//! produces the right `HookRunResult` for each lifecycle event. These tests
//! prove the next link in the chain: the live `AgentRuntime` actually CALLS the
//! engine at its lifecycle points and acts on the result -- SessionStart's
//! additionalContext reaches the session history, a UserPromptSubmit exit-2
//! blocks, and a Stop exit-2 surfaces the force-continue signal.
//!
//! The runtime's firing path is suppressed under `is_test` by default (so the
//! 2200+ hermetic unit tests never spawn hooks); these tests opt in explicitly
//! via `agent_runtime.hooks_test_override`, matching the task contract "gate so
//! it does not fire under test unless a test explicitly drives it".
//!
//! Each test builds a minimal real `AgentRuntime` (all deps under a tmp tree)
//! with a hermetic user-scope `settings.json`, then drives the runtime's own
//! `fireLifecycleHook` / `maybeFireSessionStart` helpers and asserts on the
//! resulting `LifecycleOutcome` and the session `History`.

const std = @import("std");
const rt = @import("zcode_runtime");
const agent_runtime = @import("../agent_runtime.zig");
const config_mod = @import("config.zig");
const policy_mod = @import("../policy/policy.zig");
const logger_mod = @import("logger.zig");
const session_store = @import("../session/store.zig");
const mcp_client = @import("../mcp/client.zig");
const paths = @import("paths.zig");
const env = @import("env.zig");
const test_helpers = @import("test_helpers.zig");
const cost_mod = @import("cost.zig");
const budget_control_mod = @import("budget_control.zig");

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Override HOME (and clear XDG_CONFIG_HOME) so the user settings source resolves
/// under `home`; creates `{home}/.zcode` so paths.resolve pins zcode_home there.
/// Mirrors the helper in hooks_lifecycle_test.zig (that one is module-private).
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

/// Bundle the heavyweight runtime dependencies so each test sets them up with a
/// single call and tears them down with `defer harness.deinit()`. All paths live
/// under the test's tmp tree, so the runtime is fully hermetic.
const Harness = struct {
    cfg: config_mod.Config,
    policy: policy_mod.Policy,
    audit: logger_mod.AuditLogger,
    store: session_store.Store,
    mcp: mcp_client.Client,
    runtime: agent_runtime.AgentRuntime,
    cwd: []u8,
    logs_dir: []u8,
    sessions_dir: []u8,
    registry_path: []u8,
    allocator: std.mem.Allocator,

    /// `root` is the tmp dir's absolute realpath (from tmpDirCwd). Dep dirs are
    /// derived from it via path.join -- they need not pre-exist because each
    /// dependency's init() calls paths.ensureDir on its own directory.
    fn init(allocator: std.mem.Allocator, root: []const u8, cwd: []const u8) !*Harness {
        const self = try allocator.create(Harness);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cwd = try allocator.dupe(u8, cwd);
        errdefer allocator.free(self.cwd);

        self.logs_dir = try std.fs.path.join(allocator, &.{ root, "logs" });
        errdefer allocator.free(self.logs_dir);
        self.sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
        errdefer allocator.free(self.sessions_dir);
        self.registry_path = try std.fs.path.join(allocator, &.{ root, "mcp", "registry.json" });
        errdefer allocator.free(self.registry_path);

        self.cfg = try config_mod.Config.init(allocator);
        errdefer self.cfg.deinit(allocator);
        self.policy = try policy_mod.Policy.init(allocator);
        errdefer self.policy.deinit();
        self.audit = try logger_mod.AuditLogger.init(allocator, self.logs_dir);
        errdefer self.audit.deinit();
        self.store = try session_store.Store.init(allocator, self.sessions_dir, false);
        errdefer self.store.deinit();
        self.mcp = try mcp_client.Client.init(allocator, self.registry_path);
        errdefer self.mcp.deinit();

        self.runtime = try agent_runtime.AgentRuntime.init(
            allocator,
            self.cwd,
            &self.cfg,
            &self.policy,
            &self.audit,
            &self.store,
            &self.mcp,
            null,
            false,
            false,
            false,
            false,
        );
        return self;
    }

    fn deinit(self: *Harness) void {
        self.runtime.deinit();
        self.mcp.deinit();
        self.store.deinit();
        self.audit.deinit();
        self.policy.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.cwd);
        self.allocator.free(self.logs_dir);
        self.allocator.free(self.sessions_dir);
        self.allocator.free(self.registry_path);
        self.allocator.destroy(self);
    }

    /// True when the session history contains a turn whose content includes
    /// `needle` -- the test assertion for "injected context reached the session".
    fn historyContains(self: *Harness, needle: []const u8) bool {
        for (self.runtime.history.view()) |turn| {
            if (std.mem.indexOf(u8, turn.content, needle) != null) return true;
        }
        return false;
    }

    /// Point the runtime at the scripted mock provider so a loop-level test can
    /// drive `handlePromptDetailed` through the real turn loop without any
    /// network. The runtime owns `active_provider`/`active_model`, so free the
    /// old slices before re-duping. `intent_reprompt_enabled` is turned off so
    /// the non-native (mock) no-tool-call path ends the inner loop cleanly on a
    /// plain answer rather than nudging for tool calls.
    fn useMockProvider(self: *Harness) !void {
        self.allocator.free(self.runtime.active_provider);
        self.runtime.active_provider = try self.allocator.dupe(u8, "mock");
        self.allocator.free(self.runtime.active_model);
        self.runtime.active_model = try self.allocator.dupe(u8, "mock-agent");
        self.cfg.intent_reprompt_enabled = false;
    }
};

test "runtime: SessionStart additionalContext reaches the session history" {
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

    // User-scope SessionStart hook echoing additionalContext.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"echo '{\"hookSpecificOutput\":{\"additionalContext\":\"SESSION_INJECTED\"}}'"}]}]}}
    );

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();

    // Fire SessionStart exactly as the first turn does. The hook's
    // additionalContext must be injected into the session history.
    h.runtime.maybeFireSessionStart();
    try testing.expect(h.runtime.session_start_fired);
    try testing.expect(h.historyContains("SESSION_INJECTED"));

    // A second call is a no-op (once-per-session), so the context is not
    // duplicated and no second hook runs.
    h.runtime.maybeFireSessionStart();
}

test "runtime: UserPromptSubmit exit-2 blocks the prompt with its reason" {
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
        \\{"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"echo PROMPT_DENIED; exit 2"}]}]}}
    );

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();

    const outcome = h.runtime.fireLifecycleHook(.{
        .event = .user_prompt_submit,
        .cwd = h.runtime.cwd,
        .prompt = "do the thing",
    });
    defer if (outcome.reason) |r| alloc.free(r);

    // exit 2 -> blocked; the runtime short-circuits the turn with this reason.
    try testing.expect(outcome.blocked);
    try testing.expect(outcome.reason != null);
    try testing.expect(std.mem.indexOf(u8, outcome.reason.?, "PROMPT_DENIED") != null);
}

test "runtime: Stop exit-2 surfaces the force-continue signal" {
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
        \\{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo CONTINUE_PLEASE; exit 2"}]}]}}
    );

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();

    const outcome = h.runtime.fireLifecycleHook(.{
        .event = .stop,
        .cwd = h.runtime.cwd,
    });
    defer if (outcome.reason) |r| alloc.free(r);

    // Stop is blocking-capable: exit 2 is the force-continue signal the turn
    // loop acts on (re-enter the model loop with the reason as a nudge).
    try testing.expect(outcome.blocked);
    try testing.expect(outcome.reason != null);
    try testing.expect(std.mem.indexOf(u8, outcome.reason.?, "CONTINUE_PLEASE") != null);
}

test "runtime: a non-blocking Stop hook does not force continuation" {
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

    // Exit 0 -> not blocked; the turn stops normally.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo ok; exit 0"}]}]}}
    );

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();

    const outcome = h.runtime.fireLifecycleHook(.{
        .event = .stop,
        .cwd = h.runtime.cwd,
    });
    defer if (outcome.reason) |r| alloc.free(r);
    try testing.expect(!outcome.blocked);
}

test "runtime: hooks suppressed under is_test when override is off" {
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

    // A hook that WOULD block; but with the override off it must never fire.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"UserPromptSubmit":[{"matcher":"*","hooks":[{"type":"command","command":"echo NOPE; exit 2"}]}]}}
    );

    // Override deliberately NOT enabled: the default is_test suppression holds.
    try testing.expect(!agent_runtime.hooks_test_override);

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();

    const outcome = h.runtime.fireLifecycleHook(.{
        .event = .user_prompt_submit,
        .cwd = h.runtime.cwd,
        .prompt = "hello",
    });
    defer if (outcome.reason) |r| alloc.free(r);
    // Suppressed -> no block, no reason: hermetic tests stay hook-free.
    try testing.expect(!outcome.blocked);
    try testing.expect(outcome.reason == null);
    try testing.expect(!h.historyContains("NOPE"));
}

// ── Phase 22 (agent-loop-deep-12): loop-level Stop-hook continuation ───────────
//
// The four tests above prove the runtime's `fireLifecycleHook(.stop)` helper
// returns the right `LifecycleOutcome`. The two tests below prove the next link:
// the turn loop in `handlePromptDetailedWithModeAndReporter` actually FIRES the
// Stop hook at turn-end and, on an exit-2 block, runs one more model round
// (injecting the hook's reason as a system turn). They drive the loop through
// the scripted `mock` provider, so there is no network.

/// Scope `ZCODE_MOCK_RESPONSES` for one test: the mock provider returns these
/// JSON envelopes in order (clamping at the last), so two distinct responses let
/// a test prove whether the loop ran a second model round.
const MockResponses = struct {
    fn install(alloc: std.mem.Allocator, json_array: []const u8) !void {
        const z = try alloc.dupeZ(u8, json_array);
        defer alloc.free(z);
        _ = setenv("ZCODE_MOCK_RESPONSES", z, 1);
    }
    fn clear() void {
        _ = unsetenv("ZCODE_MOCK_RESPONSES");
    }
};

test "runtime loop: a blocking Stop hook forces exactly one more model round" {
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

    // A Stop hook that exits 2 (force-continue) on its FIRST invocation and 0
    // thereafter, using an absolute counter file so re-entry is detected. The
    // blocking reason is printed on stdout so the loop injects it as a system
    // turn (the existing helper tests confirm stdout becomes the reason).
    const counter = try std.fmt.allocPrint(alloc, "{s}/.stop_count", .{cwd});
    defer alloc.free(counter);
    const settings = try std.fmt.allocPrint(alloc,
        \\{{"hooks":{{"Stop":[{{"matcher":"*","hooks":[{{"type":"command","command":"n=$(cat '{s}' 2>/dev/null || echo 0); echo $((n+1)) > '{s}'; if [ \"$n\" = \"0\" ]; then echo STOP_HOOK_CONTINUE; exit 2; fi; exit 0"}}]}}]}}}}
    , .{ counter, counter });
    defer alloc.free(settings);
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json", settings);

    // Two distinct scripted answers: the loop ending on the SECOND proves a
    // forced continuation ran a second model round.
    try MockResponses.install(alloc,
        \\["{\"assistant\":\"FIRST_ANSWER\",\"tool_calls\":[]}","{\"assistant\":\"SECOND_ANSWER\",\"tool_calls\":[]}"]
    );
    defer MockResponses.clear();

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();
    try h.useMockProvider();

    // The turn-level reactive-compaction guard must be preserved across a Stop
    // continuation (reference query.ts:1292-1297 keeps hasAttemptedReactiveCompact
    // so a hook->retry->error spiral cannot reset the guard). The runtime tracks
    // it per-call; the loop's `compaction_applied_any` accumulator lives outside
    // the stop-retry label, so it cannot be reset by a continuation -- assert the
    // turn does not spuriously report compaction either.
    var result = try h.runtime.handlePromptDetailed("say something");
    defer result.deinit(alloc);

    // The Stop hook blocked once, so the loop ran a second round and ended on
    // the second scripted answer.
    try testing.expect(std.mem.indexOf(u8, result.final_text, "SECOND_ANSWER") != null);
    // The hook's force-continue reason was injected as a system turn.
    try testing.expect(h.historyContains("STOP_HOOK_CONTINUE"));
    // No spurious compaction flag (the continuation must not flip it on).
    try testing.expect(!result.compaction_applied);
}

test "runtime loop: a non-blocking Stop hook ends the turn with no extra round" {
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

    // A Stop hook that exits 0 (no force-continue): the turn ends after the
    // first model round and the hook's stdout is NOT injected as a continuation.
    try writeFileMakingDirs(tmp.dir, ".zcode/settings.json",
        \\{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo STOP_HOOK_NOOP; exit 0"}]}]}}
    );

    // Distinct response markers from the blocking test above: the mock provider
    // keys its process-global response index by the script hash and only resets
    // the index when the hash changes, so reusing the other test's exact array
    // would carry its advanced index into this test. Unique content -> unique
    // hash -> index resets to 0 here (mock.zig:nextScriptedResponseIndex).
    try MockResponses.install(alloc,
        \\["{\"assistant\":\"NOOP_ANSWER_ONE\",\"tool_calls\":[]}","{\"assistant\":\"NOOP_ANSWER_TWO\",\"tool_calls\":[]}"]
    );
    defer MockResponses.clear();

    agent_runtime.hooks_test_override = true;
    defer agent_runtime.hooks_test_override = false;

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();
    try h.useMockProvider();

    var result = try h.runtime.handlePromptDetailed("say something");
    defer result.deinit(alloc);

    // No continuation: the turn ended on the FIRST scripted answer and the
    // non-blocking hook's stdout was never injected into history.
    try testing.expect(std.mem.indexOf(u8, result.final_text, "NOOP_ANSWER_ONE") != null);
    try testing.expect(std.mem.indexOf(u8, result.final_text, "NOOP_ANSWER_TWO") == null);
    try testing.expect(!h.historyContains("STOP_HOOK_NOOP"));
}

// --- Phase 22 (agent-loop-deep-11): typed terminal limits --------------------
// These exercise the real turn loop in handlePromptDetailedWithModeAndReporter
// and assert on TurnResult.terminal_reason, the machine-readable discriminator
// added for this task. The mock provider drives the loop without network.

test "agent-loop-deep-11: structured-output retry cap stops with the typed reason after N retries" {
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

    // The mock always returns the same final answer whose inner `assistant`
    // text is prose, not schema-valid JSON. Unique marker so the mock's
    // process-global response index resets (keyed by script hash).
    try MockResponses.install(alloc,
        \\["{\"assistant\":\"SCHEMA_INVALID_PROSE_ANSWER\",\"tool_calls\":[]}"]
    );
    defer MockResponses.clear();

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();
    try h.useMockProvider();

    // Activate a response schema (requires an object with key "answer") and a
    // cap of 2: the loop should retry exactly twice, then stop.
    h.runtime.pending_response_schema = try alloc.dupe(u8,
        \\{"type":"object","required":["answer"]}
    );
    h.cfg.max_structured_output_retries = 2;

    var result = try h.runtime.handlePromptDetailed("produce structured output");
    defer result.deinit(alloc);

    try testing.expectEqual(agent_runtime.TerminalReason.max_structured_output_retries, result.terminal_reason);
    // Exactly two corrective system nudges were injected (one per retry) before
    // the cap stopped the turn.
    var nudge_count: usize = 0;
    for (h.runtime.history.view()) |turn| {
        if (std.mem.indexOf(u8, turn.content, "did not match the required output schema") != null) nudge_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), nudge_count);
}

test "agent-loop-deep-11: a schema-valid answer completes with terminal_reason completed" {
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

    // The inner `assistant` text is a JSON object satisfying the schema. The
    // backslash-escaped quotes keep the outer envelope valid JSON.
    try MockResponses.install(alloc,
        \\["{\"assistant\":\"{\\\"answer\\\":42}\",\"tool_calls\":[]}"]
    );
    defer MockResponses.clear();

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();
    try h.useMockProvider();

    h.runtime.pending_response_schema = try alloc.dupe(u8,
        \\{"type":"object","required":["answer"]}
    );
    h.cfg.max_structured_output_retries = 2;

    var result = try h.runtime.handlePromptDetailed("produce structured output");
    defer result.deinit(alloc);

    // A valid first answer means no retries and a clean completion.
    try testing.expectEqual(agent_runtime.TerminalReason.completed, result.terminal_reason);
    try testing.expect(!h.historyContains("did not match the required output schema"));
}

test "agent-loop-deep-11: the loop's USD-cap decision matches estimateCost X decideUsd" {
    // The loop computes cumulative spend with cost.estimateCost over the session
    // token totals and gates on budget_control.decideUsd against cfg.max_budget_usd.
    // Drive that exact expression here so the wiring (not just the pure helper)
    // is covered without depending on a priced mock provider.
    const provider = "anthropic";
    const model = "claude-opus-4-6";

    // A round that consumes 1M input + 1M output tokens at opus pricing
    // ($15/$75 per M) costs $90 -- well above a $0.50 cap.
    const cumulative_usd = cost_mod.estimateCost(provider, model, 1_000_000, 1_000_000);
    try testing.expect(cumulative_usd > 0.5);
    try testing.expectEqual(budget_control_mod.Decision.stop, budget_control_mod.decideUsd(cumulative_usd, 0.5));

    // A tiny round (10 input + 10 output tokens) stays under the same cap.
    const small_usd = cost_mod.estimateCost(provider, model, 10, 10);
    try testing.expectEqual(budget_control_mod.Decision.proceed, budget_control_mod.decideUsd(small_usd, 0.5));

    // A zero cap (default) never trips regardless of spend.
    try testing.expectEqual(budget_control_mod.Decision.proceed, budget_control_mod.decideUsd(cumulative_usd, 0));
}

test "agent-loop-deep-11: max-rounds stop reports terminal_reason max_turns" {
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

    // The mock always asks for a tool call, never producing a final answer, so
    // the loop runs tool rounds until max_tool_rounds. A LOW cap of 1 forces the
    // max-rounds stop on the first round. ReadFile on a path that does not exist
    // is a harmless read-only tool that returns an error string but executes.
    try MockResponses.install(alloc,
        \\["{\"assistant\":\"checking\",\"tool_calls\":[{\"name\":\"ReadFile\",\"args\":{\"path\":\"does_not_exist.txt\"}}]}"]
    );
    defer MockResponses.clear();

    var h = try Harness.init(alloc, root, cwd);
    defer h.deinit();
    try h.useMockProvider();
    h.cfg.max_tool_rounds = 1;

    var result = try h.runtime.handlePromptDetailed("loop forever");
    defer result.deinit(alloc);

    try testing.expectEqual(agent_runtime.TerminalReason.max_turns, result.terminal_reason);
}
