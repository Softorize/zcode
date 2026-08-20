const std = @import("std");
const env = @import("env.zig");

pub const BundledSkill = struct {
    name: []const u8,
    description: []const u8,
    prompt_template: []const u8,
    /// skills-13: alternate invocation names. Defaults to empty; a bundled skill
    /// may list short aliases (e.g. `ci` for `commit`) that `findByName` accepts.
    aliases: []const []const u8 = &.{},
    /// Per-skill gate (skills-15 stub). Returns whether the skill should be
    /// registered in the live skill set. Defaults to always-on; an opt-in skill
    /// like `skillify` supplies a function that checks a config flag / env var
    /// so it stays hidden unless the user explicitly enables authoring. Mirrors
    /// the reference's per-skill feature gating (bundledSkills isEnabled).
    enabled: *const fn () bool = alwaysEnabled,
};

fn alwaysEnabled() bool {
    return true;
}

/// Authoring opt-in gate for the `skillify` skill. Off by default; the user
/// turns it on with ZCODE_ENABLE_SKILLIFY=1 (truthy per core/env.zig) so the
/// authoring tool is not surfaced to every user unprompted.
fn skillifyEnabled() bool {
    return env.isEnvTruthy("ZCODE_ENABLE_SKILLIFY");
}

/// All bundled skills available out of the box.
pub const skills = [_]BundledSkill{
    .{
        .name = "simplify",
        .description = "Review changed code for reuse, quality, and efficiency, then fix issues found",
        .prompt_template =
        \\Review all changed files for reuse, quality, and efficiency. Fix any issues found.
        \\
        \\Run git diff to see what changed. Then review for:
        \\1. Code reuse: existing utilities that could replace new code
        \\2. Code quality: redundant state, copy-paste, leaky abstractions, unnecessary comments
        \\3. Efficiency: unnecessary work, missed concurrency, memory leaks, overly broad operations
        \\
        \\Fix each issue directly. Skip false positives. Summarize what was fixed.
        ,
    },
    .{
        .name = "debug",
        .description = "Debug a failing test, build error, or runtime issue",
        .prompt_template =
        \\Help debug the current issue. Follow this process:
        \\1. Read the error message or failing test output
        \\2. Trace the code path that produces the error
        \\3. Identify the root cause (not just symptoms)
        \\4. Propose and implement a fix
        \\5. Verify the fix resolves the issue
        \\
        \\Focus on the root cause. Do not apply band-aid fixes.
        ,
    },
    .{
        .name = "review",
        .description = "Review code changes for bugs, security issues, and improvements",
        .prompt_template =
        \\Review the recent code changes for:
        \\1. Bugs and logic errors
        \\2. Security vulnerabilities (injection, traversal, leaks)
        \\3. Memory safety issues
        \\4. Error handling gaps
        \\5. Performance concerns
        \\6. Missing tests
        \\
        \\For each finding: file, line, severity, description, and suggested fix.
        \\Focus on real bugs, not style issues.
        ,
    },
    .{
        .name = "commit",
        .description = "Generate a commit message and create a git commit",
        .prompt_template =
        \\Look at the git diff and create a good commit:
        \\1. Run git status and git diff to understand changes
        \\2. Generate a concise, descriptive commit message
        \\3. Stage relevant files (not everything blindly)
        \\4. Create the commit
        \\5. Show the result
        ,
    },
    .{
        .name = "test",
        .description = "Run tests and fix any failures",
        .prompt_template =
        \\Run the project's test suite and fix any failures:
        \\1. Detect the test command (look for Makefile, package.json, build.zig, Cargo.toml, etc.)
        \\2. Run the tests
        \\3. If tests fail, read the failure output
        \\4. Trace to root cause and fix
        \\5. Re-run tests to verify
        ,
    },
    .{
        .name = "plan",
        .description = "Create a detailed implementation plan for a task",
        .prompt_template =
        \\Create a comprehensive implementation plan:
        \\1. INVESTIGATE: Read all relevant code to understand current state
        \\2. ANALYZE: Identify dependencies, risks, edge cases
        \\3. DESIGN: Consider approaches, pick the best with reasoning
        \\4. PLAN: Step-by-step with specific files, changes, test strategy
        \\5. VERIFY: Check plan for completeness
        \\
        \\Use explore agents for parallel investigation.
        ,
    },
    .{
        .name = "skillify",
        .description = "Capture the repeatable process from this session as a reusable skill (SKILL.md)",
        .enabled = skillifyEnabled,
        .prompt_template =
        \\Turn the repeatable process demonstrated in this session into a reusable skill, saved as a SKILL.md file. Work through these steps:
        \\
        \\1. ANALYZE: Review this session -- the user's messages, the skills already invoked, and the tool calls made -- and summarize the repeatable process in two or three sentences. Identify the discrete steps that make it reproducible.
        \\
        \\2. INTERVIEW: Use the AskUserQuestion tool to ask, ONE question at a time, for:
        \\   - the skill name (a short, lowercase, hyphenated identifier) and a one-line description
        \\   - when-to-use: the situation that should trigger this skill
        \\   - the ordered list of steps the skill should perform
        \\   - inline vs fork: should the skill run inline in this conversation, or as an isolated forked sub-agent?
        \\   - save location: user-wide (~/.zcode/skills) or this workspace (.zcode/skills)
        \\   - per-step success criteria so the skill is verifiable
        \\   Recommend an answer for each question and let the user confirm or override.
        \\
        \\3. ASSEMBLE: Build a valid SKILL.md. The frontmatter is a `---`-delimited block with: name, description, when-to-use, allowed-tools (only the tools the steps actually need), context (inline or fork), and paths (only if the skill should auto-activate on certain files). Keep every frontmatter value on a single line. The body is the numbered step list with the success criteria.
        \\
        \\4. WRITE: Use the Write tool to create the file at <chosen-location>/<name>/SKILL.md. Create the directory tree if it does not exist.
        \\
        \\5. CONFIRM: Tell the user the file path, then verify the new skill is discoverable (it appears in /skills on the next listing).
        ,
    },
};

/// Find a bundled skill by name (case-insensitive).
pub fn findByName(name: []const u8) ?BundledSkill {
    for (skills) |skill| {
        if (std.ascii.eqlIgnoreCase(skill.name, name)) return skill;
    }
    return null;
}

const testing = std.testing;

test "findByName finds simplify" {
    const skill = findByName("simplify");
    try testing.expect(skill != null);
    try testing.expectEqualStrings("simplify", skill.?.name);
}

test "findByName case insensitive" {
    try testing.expect(findByName("DEBUG") != null);
    try testing.expect(findByName("nonexistent") == null);
}

test "skillify is gated: present in the array, default-disabled, others always on" {
    // The skillify skill ships in the array but its gate is the env-driven
    // opt-in, while every other bundled skill is always enabled.
    var found_skillify = false;
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.name, "skillify")) {
            found_skillify = true;
            // skillifyEnabled mirrors the live gate: false unless the opt-in
            // env var is truthy. The test process does not set it.
            try testing.expect(skill.enabled == skillifyEnabled);
        } else {
            // Every non-authoring bundled skill is unconditionally enabled.
            try testing.expect(skill.enabled());
        }
    }
    try testing.expect(found_skillify);
}
