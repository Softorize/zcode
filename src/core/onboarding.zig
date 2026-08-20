const std = @import("std");
const std_io = @import("std_io.zig");
const rt = @import("zcode_runtime");
const runtime_state = @import("runtime_state.zig");
const kairos_lock = @import("kairos_lock.zig");

/// Ported from claude-code-main/src/projectOnboardingState.ts.
///
/// Per-workspace onboarding checklist -- "have you created a
/// ZCODE.md for this project yet?" style hints that disappear
/// once the user completes them. zcode's /onboarding command
/// used to be static help text; porting this helper lets us
/// render a per-workspace status panel so returning users see
/// "ZCODE.md: yes" instead of re-reading the setup walkthrough.
pub const Step = struct {
    /// Stable identifier used by callers that want to render
    /// a specific step (e.g. only the ZCODE.md row).
    key: []const u8,
    /// Human-readable description shown in the /onboarding panel.
    text: []const u8,
    /// True when the step has been satisfied -- e.g. ZCODE.md
    /// exists on disk in the workspace root.
    is_complete: bool,
    /// True when the step is something the user could mark
    /// complete by taking an action right now. Non-completable
    /// steps show as informational only.
    is_completable: bool,
    /// True when the step makes sense in the current context.
    /// For example, the "create your first workspace" step is
    /// disabled once the cwd has source files in it.
    is_enabled: bool,
};

pub const RuntimeContext = struct {
    active_provider: []const u8 = "",
    active_model: []const u8 = "",
};

pub const Snapshot = struct {
    steps: [4]Step,
    workspace_empty: bool,
    has_instruction_file: bool,
    provider_configured: bool,
    api_key_ready: bool,

    pub fn needsProviderGuide(self: Snapshot) bool {
        return !self.provider_configured or !self.api_key_ready;
    }
};

pub fn buildSnapshot(cwd: []const u8, runtime: RuntimeContext) Snapshot {
    const has_instruction_file = hasInstructionFile(cwd);
    const workspace_empty = isDirEmpty(cwd);
    const provider_configured = hasConfiguredProvider(runtime.active_provider, runtime.active_model);
    const api_key_ready = if (provider_configured)
        hasActiveProviderAccess(runtime.active_provider)
    else
        false;

    return .{
        .steps = .{
            .{
                .key = "config",
                .text = "Pick an active provider/model: use /model or /config set default_provider <name> and /config set default_model <model>.",
                .is_complete = provider_configured,
                .is_completable = true,
                .is_enabled = true,
            },
            .{
                .key = "api_key",
                .text = "Set the API key for your active provider (for example ANTHROPIC_API_KEY or OPENAI_API_KEY).",
                .is_complete = api_key_ready,
                .is_completable = true,
                .is_enabled = true,
            },
            .{
                .key = "workspace",
                .text = "Bootstrap a workspace: clone a repo or ask zcode to scaffold a project.",
                .is_complete = false, // informational step; never auto-completed
                .is_completable = true,
                .is_enabled = workspace_empty,
            },
            .{
                .key = "zcode_md",
                .text = "Run /init to create a ZCODE.md instruction file for this repo.",
                .is_complete = has_instruction_file,
                .is_completable = true,
                .is_enabled = !workspace_empty,
            },
        },
        .workspace_empty = workspace_empty,
        .has_instruction_file = has_instruction_file,
        .provider_configured = provider_configured,
        .api_key_ready = api_key_ready,
    };
}

/// Build the current onboarding-step snapshot for `cwd`. Returned
/// slice points into static string storage so there's nothing to
/// free. `cwd` is used for filesystem checks only; no strings are
/// duplicated from it.
pub fn getSteps(cwd: []const u8, runtime: RuntimeContext) [4]Step {
    return buildSnapshot(cwd, runtime).steps;
}

pub fn providerApiKeyEnvVar(provider_raw: []const u8) ?[]const u8 {
    const provider = std.mem.trim(u8, provider_raw, " \t\r\n");
    if (provider.len == 0 or std.mem.eql(u8, provider, "unknown")) return null;
    if (std.mem.eql(u8, provider, "openai")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider, "openai-compatible")) return "OPENAI_COMPAT_API_KEY";
    if (std.mem.eql(u8, provider, "deepseek")) return "DEEPSEEK_API_KEY";
    if (std.mem.eql(u8, provider, "anthropic")) return "ANTHROPIC_API_KEY";
    if (std.mem.eql(u8, provider, "gemini")) return "GEMINI_API_KEY";
    if (std.mem.eql(u8, provider, "groq")) return "GROQ_API_KEY";
    if (std.mem.eql(u8, provider, "openrouter")) return "OPENROUTER_API_KEY";
    if (std.mem.eql(u8, provider, "azure") or std.mem.eql(u8, provider, "azure-openai")) return "AZURE_OPENAI_API_KEY";
    return null;
}

pub fn hasActiveProviderAccess(provider_raw: []const u8) bool {
    const provider = std.mem.trim(u8, provider_raw, " \t\r\n");
    if (provider.len == 0 or std.mem.eql(u8, provider, "unknown")) return false;
    if (std.mem.eql(u8, provider, "local") or std.mem.eql(u8, provider, "ollama") or std.mem.eql(u8, provider, "mock")) {
        return true;
    }
    const env_name = providerApiKeyEnvVar(provider) orelse return false;
    if (@import("env.zig").getenv(env_name)) |value| {
        return value.len > 0;
    }
    return false;
}

pub fn needsInstructionFile(cwd: []const u8) bool {
    const snapshot = buildSnapshot(cwd, .{});
    return !snapshot.workspace_empty and !snapshot.has_instruction_file;
}

/// Short-circuit: is every enabled + completable step already
/// complete? Matches the reference's isProjectOnboardingComplete.
/// Callers can use this to decide whether to show a first-run
/// nudge in the welcome banner.
pub fn isProjectOnboarded(cwd: []const u8, runtime: RuntimeContext) bool {
    const steps = getSteps(cwd, runtime);
    for (steps) |step| {
        if (step.is_completable and step.is_enabled and !step.is_complete) {
            return false;
        }
    }
    return true;
}

/// The reference's `isProjectOnboardingComplete` (projectOnboardingState.ts:43)
/// checks only the workspace + instruction-file steps, NOT the
/// provider/api-key steps zcode added to `buildSnapshot`. The faithful gate
/// over the two reference-relevant steps is:
///
///   - empty workspace  -> not complete (the "bootstrap a workspace" step is
///                         enabled and never auto-completes)
///   - non-empty + has ZCODE.md/CLAUDE.md -> complete
///   - non-empty + no instruction file    -> not complete
///
/// This is deliberately narrower than `isProjectOnboarded` (which also requires
/// a configured provider + credentials), so the nudge graduates on the same
/// signal the reference uses: the project's instruction file existing.
pub fn isProjectOnboardingComplete(cwd: []const u8) bool {
    const snapshot = buildSnapshot(cwd, .{});
    if (snapshot.workspace_empty) return false;
    return snapshot.has_instruction_file;
}

/// Should the first-run onboarding nudge be shown for `cwd`? Mirrors
/// `shouldShowProjectOnboarding` (projectOnboardingState.ts:63): hidden once the
/// project has been marked completed, once the nudge has been seen >= 4 times,
/// or once onboarding is already complete; shown otherwise. `state` is a loaded
/// `runtime_state.State` (the caller owns its lifetime); this function is
/// IO-free apart from the filesystem check `isProjectOnboardingComplete` does.
pub fn shouldShowProjectOnboardingState(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    state: *const runtime_state.State,
) bool {
    const key = kairos_lock.projectKey(allocator, cwd) catch return false;
    defer allocator.free(key);
    const ob = runtime_state.getProjectOnboarding(state, key);
    if (ob.completed or ob.seen_count >= 4) return false;
    return !isProjectOnboardingComplete(cwd);
}

/// Public entry point: load state, decide, free. Returns false on any state-load
/// error (fail closed -- a missing/corrupt state file should not spam the nudge).
pub fn shouldShowProjectOnboarding(allocator: std.mem.Allocator, cwd: []const u8) bool {
    var state = runtime_state.load(allocator);
    defer state.deinit();
    return shouldShowProjectOnboardingState(allocator, cwd, &state);
}

/// Persist `completed = true` for `cwd` when onboarding is complete. No-op when
/// already completed (matches the reference's cached-config short-circuit) or
/// when onboarding is not yet complete. Best-effort. Path-injected for tests.
pub fn maybeMarkCompleteAtPath(allocator: std.mem.Allocator, cwd: []const u8, state_path: []const u8) void {
    const key = kairos_lock.projectKey(allocator, cwd) catch return;
    defer allocator.free(key);

    var state = runtime_state.loadAtPath(allocator, state_path);
    defer state.deinit();

    const ob = runtime_state.getProjectOnboarding(&state, key);
    if (ob.completed) return; // already marked; avoid a needless write
    if (!isProjectOnboardingComplete(cwd)) return;

    runtime_state.setProjectOnboardingAtPath(allocator, state_path, key, .{
        .seen_count = ob.seen_count,
        .completed = true,
    });
}

/// Public entry point resolving the real state.json path.
pub fn maybeMarkComplete(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = runtime_state.resolveStatePath(allocator) catch return;
    defer allocator.free(path);
    maybeMarkCompleteAtPath(allocator, cwd, path);
}

/// Increment the per-project onboarding seen-count for `cwd`. Called once each
/// time the nudge is actually rendered. Best-effort. Path-injected for tests.
pub fn incrementSeenCountAtPath(allocator: std.mem.Allocator, cwd: []const u8, state_path: []const u8) void {
    const key = kairos_lock.projectKey(allocator, cwd) catch return;
    defer allocator.free(key);

    var state = runtime_state.loadAtPath(allocator, state_path);
    defer state.deinit();

    const ob = runtime_state.getProjectOnboarding(&state, key);
    runtime_state.setProjectOnboardingAtPath(allocator, state_path, key, .{
        .seen_count = ob.seen_count + 1,
        .completed = ob.completed,
    });
}

/// Public entry point resolving the real state.json path.
pub fn incrementSeenCount(allocator: std.mem.Allocator, cwd: []const u8) void {
    const path = runtime_state.resolveStatePath(allocator) catch return;
    defer allocator.free(path);
    incrementSeenCountAtPath(allocator, cwd, path);
}

/// Render the steps as a text checklist suitable for appending
/// to the /onboarding command output. Caller owns the returned
/// slice. Format:
///
///     [x] Run /init to create a ZCODE.md instruction file for this repo.
///     [ ] Bootstrap a workspace: clone a repo...
pub fn renderChecklist(allocator: std.mem.Allocator, cwd: []const u8, runtime: RuntimeContext) ![]u8 {
    const steps = getSteps(cwd, runtime);
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (steps) |step| {
        if (!step.is_enabled) continue;
        const marker = if (step.is_complete) "[x]" else "[ ]";
        var text_buf: [192]u8 = undefined;
        const text = checklistStepText(step, runtime, text_buf[0..]);
        try out.writer().print("  {s} {s}\n", .{ marker, text });
    }
    return out.toOwnedSlice();
}

fn checklistStepText(step: Step, runtime: RuntimeContext, out: []u8) []const u8 {
    if (std.mem.eql(u8, step.key, "config")) {
        const provider = std.mem.trim(u8, runtime.active_provider, " \t\r\n");
        const model = std.mem.trim(u8, runtime.active_model, " \t\r\n");
        if (hasConfiguredProvider(provider, model)) {
            return std.fmt.bufPrint(out, "Active provider/model: {s}/{s}. Use /model to switch.", .{ provider, model }) catch step.text;
        }
        return step.text;
    }

    if (std.mem.eql(u8, step.key, "api_key")) {
        const provider = std.mem.trim(u8, runtime.active_provider, " \t\r\n");
        const model = std.mem.trim(u8, runtime.active_model, " \t\r\n");
        if (!hasConfiguredProvider(provider, model)) {
            return "After choosing a provider/model, set that provider's credentials if required.";
        }
        if (std.mem.eql(u8, provider, "local") or std.mem.eql(u8, provider, "ollama") or std.mem.eql(u8, provider, "mock")) {
            return std.fmt.bufPrint(out, "Active provider {s}/{s} is ready; no API key is required.", .{ provider, model }) catch step.text;
        }
        if (providerApiKeyEnvVar(provider)) |env_name| {
            if (step.is_complete) {
                return std.fmt.bufPrint(out, "Credentials ready for {s}/{s} via {s}.", .{ provider, model, env_name }) catch step.text;
            }
            return std.fmt.bufPrint(out, "Set {s} for the active provider ({s}/{s}).", .{ env_name, provider, model }) catch step.text;
        }
        if (step.is_complete) {
            return std.fmt.bufPrint(out, "Credentials ready for the active provider ({s}/{s}).", .{ provider, model }) catch step.text;
        }
        return std.fmt.bufPrint(out, "Set the credentials required by the active provider ({s}/{s}).", .{ provider, model }) catch step.text;
    }

    return step.text;
}

fn hasConfiguredProvider(provider_raw: []const u8, model_raw: []const u8) bool {
    const provider = std.mem.trim(u8, provider_raw, " \t\r\n");
    const model = std.mem.trim(u8, model_raw, " \t\r\n");
    return provider.len > 0 and
        model.len > 0 and
        !std.mem.eql(u8, provider, "unknown") and
        !std.mem.eql(u8, model, "unknown");
}

fn hasInstructionFile(cwd: []const u8) bool {
    return fileExists(cwd, "ZCODE.md") or fileExists(cwd, "CLAUDE.md");
}

fn fileExists(cwd: []const u8, name: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(rt.io, cwd, .{}) catch return false;
    defer dir.close(rt.io);
    dir.access(rt.io, name, .{}) catch return false;
    return true;
}

fn isDirEmpty(cwd: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(rt.io, cwd, .{ .iterate = true }) catch return false;
    defer dir.close(rt.io);
    var it = dir.iterate();
    const first = it.next(rt.io) catch return false;
    return first == null;
}

const testing = std.testing;

test "getSteps shows ZCODE.md as incomplete when missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Non-empty workspace so the zcode_md step is enabled.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "README.md", .data = "hello\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const steps = getSteps(cwd, .{});
    try testing.expectEqualStrings("zcode_md", steps[3].key);
    try testing.expect(!steps[3].is_complete);
    try testing.expect(steps[3].is_enabled);
}

test "getSteps marks ZCODE.md step complete when the file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# instructions\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const steps = getSteps(cwd, .{});
    try testing.expect(steps[3].is_complete);
}

test "getSteps accepts CLAUDE.md as a substitute for ZCODE.md" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "CLAUDE.md", .data = "legacy\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const steps = getSteps(cwd, .{});
    try testing.expect(steps[3].is_complete);
}

test "isProjectOnboarded returns false when ZCODE.md is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!isProjectOnboarded(cwd, .{
        .active_provider = "mock",
        .active_model = "mock-agent",
    }));
}

test "isProjectOnboarded returns true once ZCODE.md exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# instructions\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(isProjectOnboarded(cwd, .{
        .active_provider = "mock",
        .active_model = "mock-agent",
    }));
}

test "renderChecklist emits a [x] or [ ] for each enabled step" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# done\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const out = try renderChecklist(testing.allocator, cwd, .{
        .active_provider = "mock",
        .active_model = "mock-agent",
    });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "[x] Run /init") != null);
    // The "workspace" step is disabled when the dir is non-empty,
    // so its row must NOT appear in the rendered checklist.
    try testing.expect(std.mem.indexOf(u8, out, "Bootstrap a workspace") == null);
}

test "renderChecklist lists provider selection before credentials when nothing is configured" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const out = try renderChecklist(testing.allocator, cwd, .{});
    defer testing.allocator.free(out);

    const config_idx = std.mem.indexOf(u8, out, "Pick an active provider/model") orelse unreachable;
    const api_idx = std.mem.indexOf(u8, out, "After choosing a provider/model") orelse unreachable;
    try testing.expect(config_idx < api_idx);
}

test "renderChecklist on an empty workspace shows the bootstrap row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const out = try renderChecklist(testing.allocator, cwd, .{});
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "Bootstrap a workspace") != null);
}

test "needsInstructionFile ignores unrelated onboarding gaps once ZCODE.md exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# instructions\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!needsInstructionFile(cwd));
}

test "buildSnapshot marks local providers as api-key ready" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "README.md", .data = "hello\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const snapshot = buildSnapshot(cwd, .{
        .active_provider = "local",
        .active_model = "qwen3:32b",
    });
    try testing.expect(snapshot.provider_configured);
    try testing.expect(snapshot.api_key_ready);
    try testing.expect(!snapshot.needsProviderGuide());
}

test "renderChecklist explains that local providers do not need an api key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "README.md", .data = "hello\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const out = try renderChecklist(testing.allocator, cwd, .{
        .active_provider = "local",
        .active_model = "qwen3:32b",
    });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Active provider local/qwen3:32b is ready; no API key is required.") != null);
}

test "renderChecklist names the env var for hosted providers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "README.md", .data = "hello\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    const out = try renderChecklist(testing.allocator, cwd, .{
        .active_provider = "openai",
        .active_model = "gpt-4.1",
    });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Set OPENAI_API_KEY for the active provider (openai/gpt-4.1).") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Active provider/model: openai/gpt-4.1. Use /model to switch.") != null);
}

// Helper: a freshly loaded state from `state_path`. The caller owns it.
fn loadStateForTest(state_path: []const u8) runtime_state.State {
    return runtime_state.loadAtPath(testing.allocator, state_path);
}

test "isProjectOnboardingComplete tracks the instruction-file gate" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Non-empty workspace, no ZCODE.md/CLAUDE.md yet -> not complete.
    try tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &tmp);
    defer testing.allocator.free(cwd);

    try testing.expect(!isProjectOnboardingComplete(cwd));

    try tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# instructions\n" });
    try testing.expect(isProjectOnboardingComplete(cwd));
}

test "shouldShowProjectOnboarding: true until the seen-count cap, then false" {
    // Workspace dir (source, no ZCODE.md) and a separate state dir so the
    // state.json never lands inside the workspace itself.
    var ws_tmp = testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    try ws_tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &ws_tmp);
    defer testing.allocator.free(cwd);

    var state_tmp = testing.tmpDir(.{});
    defer state_tmp.cleanup();
    const state_dir = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &state_tmp);
    defer testing.allocator.free(state_dir);
    const state_path = try std.fs.path.join(testing.allocator, &.{ state_dir, "state.json" });
    defer testing.allocator.free(state_path);

    // Initially shown: non-empty workspace, no instruction file, seen_count 0.
    {
        var state = loadStateForTest(state_path);
        defer state.deinit();
        try testing.expect(shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }

    // Still shown after 3 renders (seen_count 1, 2, 3 -- all < 4).
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        incrementSeenCountAtPath(testing.allocator, cwd, state_path);
        var state = loadStateForTest(state_path);
        defer state.deinit();
        try testing.expect(shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }

    // The 4th render trips the cap (seen_count == 4) -> hidden.
    incrementSeenCountAtPath(testing.allocator, cwd, state_path);
    {
        var state = loadStateForTest(state_path);
        defer state.deinit();
        try testing.expect(!shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }
}

test "shouldShowProjectOnboarding: hidden once maybeMarkComplete records completion" {
    var ws_tmp = testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    // Workspace with source AND an instruction file -> onboarding is complete.
    try ws_tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "const std = @import(\"std\");\n" });
    try ws_tmp.dir.writeFile(rt.io, .{ .sub_path = "ZCODE.md", .data = "# instructions\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &ws_tmp);
    defer testing.allocator.free(cwd);

    var state_tmp = testing.tmpDir(.{});
    defer state_tmp.cleanup();
    const state_dir = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &state_tmp);
    defer testing.allocator.free(state_dir);
    const state_path = try std.fs.path.join(testing.allocator, &.{ state_dir, "state.json" });
    defer testing.allocator.free(state_path);

    // Even before marking, an already-complete project hides the nudge
    // (shouldShow returns !isComplete).
    {
        var state = loadStateForTest(state_path);
        defer state.deinit();
        try testing.expect(!shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }

    // Mark complete -> the `completed` flag is persisted.
    maybeMarkCompleteAtPath(testing.allocator, cwd, state_path);
    {
        var state = loadStateForTest(state_path);
        defer state.deinit();
        const key = try kairos_lock.projectKey(testing.allocator, cwd);
        defer testing.allocator.free(key);
        try testing.expect(runtime_state.getProjectOnboarding(&state, key).completed);
        // Completion keeps the nudge hidden even though the seen-count is 0.
        try testing.expect(!shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }

    // The completion flag survives a seen-count change: even after a render the
    // nudge stays hidden because `completed` short-circuits before the cap.
    incrementSeenCountAtPath(testing.allocator, cwd, state_path);
    {
        var state = loadStateForTest(state_path);
        defer state.deinit();
        const key = try kairos_lock.projectKey(testing.allocator, cwd);
        defer testing.allocator.free(key);
        const ob = runtime_state.getProjectOnboarding(&state, key);
        try testing.expect(ob.completed);
        try testing.expectEqual(@as(u64, 1), ob.seen_count);
        try testing.expect(!shouldShowProjectOnboardingState(testing.allocator, cwd, &state));
    }
}

test "maybeMarkComplete is a no-op when onboarding is incomplete" {
    var ws_tmp = testing.tmpDir(.{});
    defer ws_tmp.cleanup();
    // Source but no instruction file -> not complete.
    try ws_tmp.dir.writeFile(rt.io, .{ .sub_path = "main.zig", .data = "x\n" });
    const cwd = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &ws_tmp);
    defer testing.allocator.free(cwd);

    var state_tmp = testing.tmpDir(.{});
    defer state_tmp.cleanup();
    const state_dir = try @import("test_helpers.zig").tmpDirCwd(testing.allocator, &state_tmp);
    defer testing.allocator.free(state_dir);
    const state_path = try std.fs.path.join(testing.allocator, &.{ state_dir, "state.json" });
    defer testing.allocator.free(state_path);

    maybeMarkCompleteAtPath(testing.allocator, cwd, state_path);

    var state = loadStateForTest(state_path);
    defer state.deinit();
    const key = try kairos_lock.projectKey(testing.allocator, cwd);
    defer testing.allocator.free(key);
    try testing.expect(!runtime_state.getProjectOnboarding(&state, key).completed);
}
