const std = @import("std");
const env = @import("env.zig");
const skill_types = @import("skill_types.zig");

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
    /// bundled-skills-03: short label for a slash-command/skill menu. Falls
    /// back to `description` when empty (see `menuDescriptionOf`). Mirrors the
    /// reference's per-skill `menuDescription`.
    menu_description: []const u8 = "",
    /// bundled-skills-03: surfaced ahead of `description` in the model-awareness
    /// listing (skill_listing.zig summaryOf) so the model knows when to reach
    /// for this skill. Mirrors the reference's `whenToUse`.
    when_to_use: []const u8 = "",
    /// bundled-skills-03/17: `$ARGUMENTS` usage hint (e.g.
    /// "[--fix] [<pr#>|<branch>|<path>]"). Mirrors the reference `argumentHint`.
    argument_hint: []const u8 = "",
    /// bundled-skills-03/04/12/19: tools auto-allowed while the skill runs.
    /// Empty = no restriction beyond the session's normal permission gate.
    /// Mirrors the reference `allowedTools`.
    allowed_tools: []const []const u8 = &.{},
    /// bundled-skills-17: tools explicitly denied while the skill runs (ignored
    /// when `allowed_tools` is non-empty). Mirrors the reference `disallowedTools`.
    disallowed_tools: []const []const u8 = &.{},
    /// Whether a user can invoke this skill directly (`/name`). Defaults on.
    user_invocable: bool = true,
    /// bundled-skills-missed-226/228: whether the MODEL may self-invoke this
    /// skill via `Skill(action="run")`. A menu-only skill (e.g.
    /// run-skill-generator, design-sync in the reference) sets this true so it
    /// is reachable only by explicit user invocation.
    disable_model_invocation: bool = false,
    /// Model / effort overrides applied for the duration of the skill; "" means
    /// inherit the session's current value.
    model: []const u8 = "",
    effort: []const u8 = "",
    /// inline (expand into the current conversation) or fork (isolated
    /// sub-agent). Mirrors the reference `context`.
    context: skill_types.SkillContext = .inline_skill,
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
        // bundled-skills-19: 2.1.261 semantics for "debug" are session/harness
        // log diagnosis (read-only: turn on debug logging and investigate why
        // the harness itself misbehaved -- hooks not firing, MCP not
        // connecting, a tool erroring), NOT fixing a bug in the user's code.
        // The old zcode "debug" content (root-cause-and-fix-the-code) survives
        // under the distinct name "fix-bug" below.
        .name = "debug",
        .description = "Turn on debug logging and investigate problems",
        .when_to_use = "hooks aren't firing, an MCP server won't connect, a tool call errors unexpectedly, or something about the session itself (not the user's code) is misbehaving",
        .allowed_tools = &.{ "Read", "Grep", "Glob" },
        .prompt_template =
        \\Diagnose a problem with THIS session/harness (not the user's application code). Follow this process:
        \\
        \\1. Turn on verbose/debug logging for the session (the -d/--debug flag or ZCODE_DEBUG env var; check /doctor and the CLI --help output for the exact switch this build exposes) so the next reproduction captures detail.
        \\2. Reproduce the reported problem and capture the resulting debug log or error output.
        \\3. Read the log with Read/Grep and trace which component misbehaved: hook dispatch, MCP server connection, tool-call plumbing, permission resolution, config loading, etc.
        \\4. Identify the root cause from the evidence in the log -- do not guess.
        \\5. Report the root cause and where in the log it is visible; this skill is read-only, so hand the actual fix to the user or a follow-up turn rather than editing files here.
        ,
    },
    .{
        // Renamed from the old bundled "debug" skill so the name "debug" is
        // free for the reference's session/log-diagnosis meaning above.
        .name = "fix-bug",
        .description = "Debug a failing test, build error, or runtime issue",
        .when_to_use = "a test, build, or runtime error needs a root-cause fix in the code",
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
        // bundled-skills-05: renamed from the old static "review" to the
        // reference's "code-review"; "review" kept as a legacy alias so
        // existing muscle memory (/review, Skill(name="review")) still
        // resolves. Effort levels are documented for the model rather than
        // parsed here (they select the model/agent doing the reviewing, which
        // is a session-level choice); --fix/--comment and the trailing
        // <pr#>|<branch>|<path> target ARE parsed, by `parseCodeReviewArgs`
        // below, and skills.zig's renderRun special-cases this skill's name to
        // use the parsed result instead of the generic opaque-args path.
        .name = "code-review",
        .description = "Review the current diff or a PR for bugs and cleanups",
        .when_to_use = "changes need a review pass before landing -- bugs, cleanups, or a second opinion on a diff, PR, branch, or path",
        .argument_hint = "[--fix] [--comment] [<pr#>|<branch>|<path>]",
        .aliases = &.{"review"},
        .prompt_template =
        \\Review the current diff (or the given PR/branch/path target) for:
        \\1. Bugs and logic errors
        \\2. Security vulnerabilities (injection, traversal, leaks)
        \\3. Memory safety issues
        \\4. Error handling gaps
        \\5. Performance concerns
        \\6. Missing tests
        \\
        \\For each finding: file, line, severity, description, and suggested fix.
        \\Focus on real bugs, not style issues.
        \\
        \\If the parsed task context below says fix: true, apply the findings to the working tree after reviewing (skip false positives). If it says comment: true and the target is a PR, post the findings as inline PR review comments (e.g. via `gh pr comment` / `gh pr review --comment`) instead of only printing them.
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
    .{
        // bundled-skills-04: distinct from the `/security-review` REPL command
        // in repl_commands.zig (which this skill now backs, see skills.zig
        // renderRun) -- registering it here makes it Skill-tool-discoverable
        // and gives it a real allowed-tools restriction the REPL command never
        // had (no Write/Edit: this is a read-only review).
        .name = "security-review",
        .description = "Complete a security review of the pending changes on the current branch",
        .when_to_use = "changes on this branch need a focused, high-confidence security pass before merging",
        .allowed_tools = &.{ "Bash", "Read", "Glob", "Grep", "LS", "Task" },
        .prompt_template =
        \\Perform a security review of the changes on the current branch (diff it against the branch's merge base / origin HEAD). Only report issues newly introduced by this branch -- do not comment on pre-existing security posture. Use a phased sub-task process so false positives get filtered before they reach the user:
        \\
        \\PHASE 1 -- SURVEY: Launch one sub-task (via the Agent/Task tool) that reads the branch's diff and reports every plausible vulnerability it can find, each with a file:line reference, a one-sentence description, and a confidence score from 0-10.
        \\
        \\PHASE 2 -- FILTER: For every vulnerability Phase 1 reported, launch a separate sub-task (these can run in parallel) that looks at that single finding in isolation and either confirms it with its own exploit scenario or rejects it as a false positive, again with a 0-10 confidence score.
        \\
        \\PHASE 3 -- REPORT: Keep only findings whose Phase 2 confidence is 8 or higher. Report each surviving finding with: file:line, a one-sentence description, a one-sentence exploitation scenario, and a one-sentence recommended fix, ordered by severity.
        \\
        \\HARD EXCLUSIONS -- never report any of the following as a finding:
        \\  - Denial of service / resource exhaustion from unbounded loops or large inputs
        \\  - Secrets or credentials already committed to disk elsewhere in the repo (not introduced by this diff)
        \\  - Missing rate limiting
        \\  - Memory or CPU exhaustion under adversarial input sizes
        \\  - Changes confined to documentation, comments, or test fixtures
        \\  - Purely theoretical issues with no concrete, in-repo exploitation path
        \\  - Missing input validation on values that are already trusted/internal by the surrounding code's own contract
        \\  - Style, lint, or code-quality concerns with no security implication
        \\  - Missing tests (track separately from a security finding)
        \\  - Third-party dependency vulnerabilities not newly introduced by this diff
        \\  - Verbose logging that does not itself leak secrets or PII
        \\
        \\If there are no qualifying findings, say so explicitly and note any category you could not fully verify.
        ,
    },
    .{
        .name = "update-config",
        .menu_description = "Change settings: hooks, permissions, environment variables",
        .description = "Use this skill to configure the zcode harness via settings.json. Automated behaviors (\"from now on when X\", \"each time X\", \"whenever X\", \"before/after X\") require hooks configured in settings.json - the harness executes these, not the model, so memory/preferences cannot fulfill them. Also use for: permissions (\"allow X\", \"add permission\", \"move permission to\"), env vars (\"set X=Y\"), hook troubleshooting, or any changes to settings.json/settings.local.json files.",
        .when_to_use = "the user wants a recurring/automated behavior, a permission rule changed, an environment variable set, or a hook debugged -- anything that lives in settings.json rather than in a prompt",
        .prompt_template =
        \\Configure zcode's settings.json / settings.local.json to satisfy the request:
        \\
        \\1. LOCATE: decide user scope (~/.zcode/settings.json, or ~/.claude/settings.json for cross-tool compatibility) vs project scope (.zcode/settings.json or .claude/settings.json) vs local/untracked (settings.local.json). Prefer project scope for anything the whole team should share, local scope for a single machine's overrides.
        \\2. READ the existing file (if any) so the edit merges rather than clobbers.
        \\3. EDIT the relevant section:
        \\   - Automated behavior ("whenever X, do Y") -> a `hooks` entry (PreToolUse/PostToolUse/Stop/etc. matcher + command).
        \\   - "allow/deny X" -> the `permissions.allow` / `permissions.deny` list.
        \\   - "set VAR=value" -> the `env` map.
        \\4. VALIDATE the file is still well-formed JSON before writing.
        \\5. CONFIRM what changed and where, and mention the file needs a new session (or /reload-skills / restart) to take effect if the harness does not hot-reload it.
        ,
    },
    .{
        .name = "keybindings-help",
        .description = "Customize keyboard shortcuts, rebind keys, or add chord bindings",
        .when_to_use = "the user wants to rebind a key, add a chord shortcut, change the submit key, or otherwise customize ~/.zcode/keybindings.json. Examples: \"rebind ctrl+s\", \"add a chord shortcut\", \"change the submit key\", \"customize keybindings\".",
        .allowed_tools = &.{ "Read", "Write", "Edit" },
        .prompt_template =
        \\Help the user customize their keybindings:
        \\
        \\1. READ ~/.zcode/keybindings.json (create it with an empty binding set if absent).
        \\2. Confirm the exact action, the desired key combination, and whether it should be a single chord (e.g. `ctrl+x h`) or a plain shortcut.
        \\3. Check the requested key is not one of zcode's non-rebindable or terminal-reserved keys (see src/cli/keybindings.zig for the exact reserved list; common terminal-reserved keys include ctrl+c, ctrl+z, ctrl+d) -- warn the user and suggest an alternative if it collides.
        \\4. WRITE the updated binding into keybindings.json, preserving existing bindings.
        \\5. CONFIRM the new binding and mention it takes effect on the next REPL start.
        ,
    },
    .{
        .name = "fewer-permission-prompts",
        .description = "Scan your transcripts for common read-only Bash and MCP tool calls, then add a prioritized allowlist to project .claude/settings.json to reduce permission prompts.",
        .menu_description = "Pre-approve safe read-only commands based on your usage",
        .when_to_use = "the user is tired of repeatedly approving the same safe, read-only commands and wants zcode to pre-approve them",
        .allowed_tools = &.{ "Read", "Grep", "Glob", "Write", "Edit" },
        .prompt_template =
        \\Reduce permission prompts by allowlisting the read-only commands this session (or this project's history) actually uses:
        \\
        \\1. SCAN recent session transcripts / tool-call logs for repeated Bash invocations and MCP tool calls that are read-only (git status/diff/log, ls, cat, grep, find, package-manager list/info commands, read-only MCP resource fetches -- never anything that writes, deletes, or calls out to a paid API).
        \\2. RANK them by frequency; keep the ones seen more than once or twice.
        \\3. READ the project's .claude/settings.json (or .zcode/settings.json) to see the existing permissions.allow list.
        \\4. MERGE the new read-only patterns into permissions.allow without duplicating or removing existing entries.
        \\5. CONFIRM the list you added and remind the user they can edit settings.json directly to prune it later.
        ,
    },
    .{
        .name = "loop",
        .description = "Run a prompt or slash command on a recurring interval",
        .argument_hint = "[interval] <prompt or /command>",
        .when_to_use = "the user wants a recurring task, wants to poll for status repeatedly, or asks for a delayed one-time run (\"check the deploy every 5 minutes\", \"remind me to check X in an hour\") -- not for a single one-off task",
        .prompt_template =
        \\Set up a recurring (or one-time delayed) prompt using zcode's `/loop` command: `/loop [interval] <prompt or /command>`.
        \\
        \\- interval is Ns/Nm/Nh/Nd (e.g. `5m`, `2h`); omit it to fire the prompt once immediately with no recurrence.
        \\- Under the hood `/loop` calls CronCreate to schedule the prompt and fires it once right away so the user sees it work without waiting for the first tick.
        \\- Use CronList to show the user their current loops/schedules, and CronDelete to cancel one they no longer want.
        \\- For a genuinely one-time delayed run rather than a repeating loop, prefer scheduling a single cron entry (or ScheduleWakeup, if available) instead of a recurring interval.
        \\
        \\Confirm the interval and the exact prompt/command with the user before creating the loop if either is ambiguous.
        ,
    },
    .{
        .name = "schedule",
        .description = "Create, update, list, or run scheduled agents that execute on a cron schedule",
        .aliases = &.{"routines"},
        .when_to_use = "the user wants to schedule a recurring background task, set up a cron job, or manage their existing scheduled jobs. Also for a one-time scheduled run (\"run this once at 3pm\").",
        .prompt_template =
        \\Manage the user's scheduled work using zcode's cron primitives:
        \\
        \\- CronCreate: schedule a new recurring (cron expression) or one-shot job with a prompt/command to run.
        \\- CronList: show the user's current scheduled jobs.
        \\- CronDelete: cancel a job the user no longer wants (they may know it by id or description -- use CronList first if unsure).
        \\
        \\Confirm the exact schedule (cron expression or plain-language interval translated to one) and the prompt/command to run before creating anything. For a single one-time run at a specific time, create a job that fires once rather than a recurring cron expression.
        ,
    },
    .{
        .name = "claude-api",
        .menu_description = "Build and debug apps that use the Claude API",
        .description = "Build and debug apps that use the Claude API",
        .when_to_use = "the user is building or debugging code that calls the Claude API or Anthropic SDK, or asks an LLM-shaped question (model choice, pricing, limits, caching, streaming, tool use, MCP) without naming a specific provider. Skip when another provider (OpenAI/GPT, Gemini, Llama, Mistral, Cohere, Ollama) is already in use for the task.",
        .allowed_tools = &.{"WebFetch(domain:platform.claude.com)"},
        .prompt_template =
        \\Help the user build or debug an application that calls the Claude API. Do not answer model/pricing/limits questions from memory -- fetch current details from platform.claude.com (via WebFetch) when the answer is time-sensitive (model ids, pricing, context windows, rate limits). Cover, as relevant to the question:
        \\
        \\1. Model selection: current model ids and when to pick each one for the task's latency/cost/quality tradeoff.
        \\2. Request shape: messages format, system prompts, streaming vs non-streaming responses.
        \\3. Tool use: tool/function-calling definitions, multi-turn tool-result handling.
        \\4. MCP: connecting Model Context Protocol servers as an alternative to hand-rolled tool definitions.
        \\5. Prompt caching and token counting, when the user is optimizing cost or latency.
        \\
        \\If another LLM provider is already in use for this task (OpenAI, Gemini, Llama, Mistral, Cohere, Ollama), defer to that provider's own docs instead of assuming Claude.
        ,
    },
    .{
        .name = "run",
        .menu_description = "Launch this project's app to see your change working",
        .description = "Launch and drive this project's app to see a change working",
        .when_to_use = "asked to run, start, or screenshot the app, or to confirm a change works in the real running app rather than only in its test suite",
        .prompt_template =
        \\Launch and exercise this project's actual running app so the user (or you) can see the change working, rather than stopping at the test suite:
        \\
        \\1. LOOK FIRST for a project-specific "run" skill (e.g. one authored by run-skill-generator) that already documents how to build, launch, and verify this app -- follow it if present.
        \\2. Otherwise fall back to per-project-type heuristics: `zig build run` / `npm start` / `python -m <pkg>` / `cargo run` / a server's documented dev command / opening a TUI or Electron shell / a browser-driven flow, as appropriate to what this project actually is.
        \\3. LAUNCH it and drive the specific change (open the affected screen, hit the affected endpoint, run the affected CLI path).
        \\4. OBSERVE the actual behavior (output, screenshot, logs, response body) rather than only reporting that the process started.
        \\5. REPORT what you saw, and stop the process if you started a long-running one.
        ,
    },
    .{
        .name = "explain-usage",
        .description = "See where this session's tokens went, in plain words",
        .when_to_use = "the user asks why a session is expensive, wants a token-usage breakdown, or asks where the context budget went",
        .allowed_tools = &.{ "Read", "Grep" },
        .prompt_template =
        \\Explain, in plain language, where this session's tokens went:
        \\
        \\1. Read zcode's own session cost/usage accounting (the running total the session already tracks, and /cost's breakdown) for this session.
        \\2. Identify the biggest contributors: large tool outputs (file reads, command output), the system prompt and its dynamic sections, long conversation history, repeated large file reads of the same file.
        \\3. Summarize in a few plain-English sentences, ranked biggest-to-smallest, rather than a bare table of numbers.
        \\4. If something stands out as wasteful (e.g. the same large file read many times), suggest a concrete fix (e.g. read it once, or use Grep to narrow it).
        ,
    },
    .{
        .name = "batch",
        .description = "Plan a large change; background agents each open a PR",
        .when_to_use = "a sweeping, mechanical change (migration, refactor, bulk rename) spans many files and can be decomposed into independent parallel units",
        .prompt_template =
        \\Orchestrate a large, parallelizable change as a two-phase batch:
        \\
        \\## Phase 1: Research and plan (plan mode)
        \\Investigate the codebase, identify every independent unit of work the change decomposes into (e.g. one unit per package, per file group, per migration target), and draft a plan naming each unit and the change it needs. Call ExitPlanMode to present the plan for approval before spawning anything.
        \\
        \\## Phase 2: Spawn workers (after plan approval)
        \\Once the plan is approved, spawn one background agent per work unit (via the Agent tool), each scoped to its own unit with clear instructions and acceptance criteria. Have each worker open its own PR (`gh pr create`) for its unit rather than one shared PR, so units can be reviewed and merged independently. Track and report each worker's outcome back to the user.
        ,
    },
    .{
        .name = "run-skill-generator",
        .menu_description = "Create a skill that knows how to run this project's app",
        .description = "Author or improve the run-<unit> skill - a per-project skill that tells agents how to build, launch, and drive this project's app",
        .when_to_use = "the user asks to set up the project, get it running, write run instructions, or verify build/run steps work from a clean environment",
        .disable_model_invocation = true,
        .prompt_template =
        \\Author (or improve) a project-specific "run-<unit>" skill that documents exactly how to build, launch, and verify this project's app is running:
        \\
        \\1. INVESTIGATE how this project is actually built and run today: build files, package manifests, dev scripts, README run instructions, CI config.
        \\2. VERIFY the steps work from a clean checkout (build, then launch, then a concrete way to confirm it is actually running -- a health check, a smoke test, an expected log line).
        \\3. WRITE a SKILL.md at .zcode/skills/run-<unit>/SKILL.md (name the unit after the app/service, e.g. run-server, run-cli) with the frontmatter name/description/when-to-use and a numbered body: build command, launch command, verification step, and how to stop it.
        \\4. If a run-<unit> skill already exists, read it first and improve it rather than overwriting good content.
        \\5. CONFIRM the file path so the "run" skill (bundled-skills-13) can find and use it on future invocations.
        ,
    },
};

/// bundled-skills-03: short menu label for a bundled skill, falling back to its
/// full `description` when no `menu_description` was set.
pub fn menuDescriptionOf(skill: BundledSkill) []const u8 {
    return if (skill.menu_description.len > 0) skill.menu_description else skill.description;
}

/// bundled-skills-05: the `code-review` skill's parsed argument shape. A
/// leading `--fix` and/or `--comment` token (in either order) are recognized as
/// flags; whatever remains (trimmed) is the review target (a PR number,
/// branch name, or path). Allocation-free -- `target` aliases into `args`.
pub const CodeReviewArgs = struct {
    fix: bool = false,
    comment: bool = false,
    target: []const u8 = "",
};

/// Parse `code-review`'s argument string into structured flags/target instead
/// of leaving `--fix`/`--comment`/the trailing target as opaque freeform text
/// for the model to interpret itself (skills.zig's renderRun special-cases
/// this skill's name to use the result instead of the generic builtin-args
/// path).
pub fn parseCodeReviewArgs(args: []const u8) CodeReviewArgs {
    var out = CodeReviewArgs{};
    var rest = std.mem.trim(u8, args, " \t\r\n");
    while (true) {
        if (std.mem.startsWith(u8, rest, "--fix")) {
            out.fix = true;
            rest = std.mem.trim(u8, rest["--fix".len..], " \t\r\n");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "--comment")) {
            out.comment = true;
            rest = std.mem.trim(u8, rest["--comment".len..], " \t\r\n");
            continue;
        }
        break;
    }
    out.target = rest;
    return out;
}

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

test "bundled-skills-19: debug is session/log diagnosis, read-only; fix-bug carries the old code-fixing content" {
    const dbg = findByName("debug").?;
    try testing.expectEqualStrings("Turn on debug logging and investigate problems", dbg.description);
    try testing.expectEqual(@as(usize, 3), dbg.allowed_tools.len);
    try testing.expect(std.mem.eql(u8, dbg.allowed_tools[0], "Read"));
    try testing.expect(std.mem.eql(u8, dbg.allowed_tools[1], "Grep"));
    try testing.expect(std.mem.eql(u8, dbg.allowed_tools[2], "Glob"));
    try testing.expect(std.mem.indexOf(u8, dbg.prompt_template, "Help debug the current issue") == null);

    const fix = findByName("fix-bug").?;
    try testing.expect(std.mem.indexOf(u8, fix.prompt_template, "Help debug the current issue") != null);
}

test "bundled-skills-05: code-review replaces review; parseCodeReviewArgs recognizes --fix/--comment and a target" {
    const cr = findByName("code-review").?;
    try testing.expect(std.mem.eql(u8, cr.aliases[0], "review"));
    try testing.expect(findByName("review") == null); // bundled_skills.findByName checks canonical name only; skills.zig resolves the alias

    const parsed = parseCodeReviewArgs("--fix main");
    try testing.expect(parsed.fix);
    try testing.expect(!parsed.comment);
    try testing.expectEqualStrings("main", parsed.target);

    const both = parseCodeReviewArgs("--comment --fix 123");
    try testing.expect(both.fix);
    try testing.expect(both.comment);
    try testing.expectEqualStrings("123", both.target);

    const bare = parseCodeReviewArgs("feature-branch");
    try testing.expect(!bare.fix and !bare.comment);
    try testing.expectEqualStrings("feature-branch", bare.target);

    const none = parseCodeReviewArgs("");
    try testing.expect(!none.fix and !none.comment);
    try testing.expectEqualStrings("", none.target);
}

test "bundled-skills-04: security-review excludes Write/Edit and covers the phased methodology" {
    const sr = findByName("security-review").?;
    for (sr.allowed_tools) |t| {
        try testing.expect(!std.mem.eql(u8, t, "Write"));
        try testing.expect(!std.mem.eql(u8, t, "Edit"));
    }
    try testing.expect(std.mem.indexOf(u8, sr.prompt_template, "confidence") != null);
    try testing.expect(std.mem.indexOf(u8, sr.prompt_template, "HARD EXCLUSIONS") != null);
    try testing.expect(std.mem.indexOf(u8, sr.prompt_template, "PHASE 1") != null);
    try testing.expect(std.mem.indexOf(u8, sr.prompt_template, "PHASE 2") != null);
}

test "bundled-skills-07/09/14: verbatim descriptions for update-config, fewer-permission-prompts, explain-usage" {
    try testing.expectEqualStrings(
        "Use this skill to configure the zcode harness via settings.json. Automated behaviors (\"from now on when X\", \"each time X\", \"whenever X\", \"before/after X\") require hooks configured in settings.json - the harness executes these, not the model, so memory/preferences cannot fulfill them. Also use for: permissions (\"allow X\", \"add permission\", \"move permission to\"), env vars (\"set X=Y\"), hook troubleshooting, or any changes to settings.json/settings.local.json files.",
        findByName("update-config").?.description,
    );
    try testing.expectEqualStrings(
        "Scan your transcripts for common read-only Bash and MCP tool calls, then add a prioritized allowlist to project .claude/settings.json to reduce permission prompts.",
        findByName("fewer-permission-prompts").?.description,
    );
    try testing.expectEqualStrings(
        "See where this session's tokens went, in plain words",
        findByName("explain-usage").?.description,
    );
}

test "bundled-skills-08/10/11/12/13/15: the rest of the new bundled skills resolve" {
    try testing.expect(findByName("keybindings-help") != null);
    try testing.expect(findByName("loop") != null);
    try testing.expect(findByName("run") != null);

    const sched = findByName("schedule").?;
    try testing.expect(std.mem.indexOf(u8, sched.prompt_template, "CronCreate") != null);
    try testing.expect(std.mem.indexOf(u8, sched.prompt_template, "CronList") != null);
    try testing.expect(std.mem.indexOf(u8, sched.prompt_template, "CronDelete") != null);

    const api = findByName("claude-api").?;
    var found_webfetch = false;
    for (api.allowed_tools) |t| {
        if (std.mem.startsWith(u8, t, "WebFetch")) found_webfetch = true;
    }
    try testing.expect(found_webfetch);

    const batch = findByName("batch").?;
    try testing.expect(std.mem.indexOf(u8, batch.prompt_template, "Phase 1") != null);
    try testing.expect(std.mem.indexOf(u8, batch.prompt_template, "Phase 2") != null);
}

test "bundled-skills-missed-228: run-skill-generator is menu-only (disable_model_invocation, still user-invocable)" {
    const gen = findByName("run-skill-generator").?;
    try testing.expect(gen.disable_model_invocation);
    try testing.expect(gen.user_invocable);
}

test "bundled-skills-missed-226: menuDescriptionOf falls back to description when unset" {
    // security-review sets no explicit menu_description.
    const sr = findByName("security-review").?;
    try testing.expectEqualStrings(sr.description, menuDescriptionOf(sr));
    // run has an explicit, shorter menu_description.
    const run_skill = findByName("run").?;
    try testing.expect(!std.mem.eql(u8, run_skill.menu_description, run_skill.description));
    try testing.expectEqualStrings(run_skill.menu_description, menuDescriptionOf(run_skill));
}
