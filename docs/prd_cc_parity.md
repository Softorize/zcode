## Problem Statement

zcode is a Zig reimplementation of Claude Code. Today it tracks the reference closely on a few
subsystems (prompt mechanism, skills, KAIROS) but drifts substantially elsewhere: the hook system
is a 3-event env-var shim against the reference's ~27-event JSON-contract engine, permissions are
hardcoded risk tiers instead of a rule engine, the agent loop lacks reactive recovery behaviors,
several model/user-facing identifiers differ, MCP/memory/session depth is partial, the plugin
marketplace has no backend, and many fullscreen UI overlays are data-modeled but not rendered. A
user who knows Claude Code does not yet feel fully at home in zcode, and our command/tool surface
both *lacks* reference features and *carries* extras the reference never had.

We want zcode to be functionally identical to the reference everywhere it can be, with authentication
the single deliberate exclusion.

## Solution

Bring zcode to full feature parity with the reference (`~/Downloads/claude-code-main/`), adapted to
Zig idioms and our existing terminal renderer. "Identical" means **functional equivalence**: the same
observable behavior and roughly the same on-screen content, not byte-for-byte output. Work is driven
by the gap inventory in `docs/CC_PARITY_GAP_INVENTORY.md` and delivered in nine phases. Where a
reference subsystem fundamentally needs an external runtime or Anthropic backend we cannot run (voice
STT, the Chrome extension, remote/bridge/teleport cloud services, telemetry, the Yoga layout engine),
we ship a best-effort local equivalent or a clearly-marked stub and document each deviation rather
than leave anything silently missing. Model-facing tool names and user-facing slash-command names are
reconciled to be reference-exact; internal Zig module names are left alone. Our reference-less extras
are removed to match the surface, **except** the git/commit/PR tooling that backs the user's own
workflow, and all removals land as one final reviewable commit.

## User Stories

1. As a Claude Code user switching to zcode, I want the same slash commands by the same names, so that my muscle memory works unchanged.
2. As a user, I want model-facing tools named exactly as in the reference (Read, Edit, Write, Glob, Grep, Bash, WebFetch, WebSearch, Task, TodoWrite, NotebookEdit, LSP, ToolSearch, Skill, Sleep), so that the agent behaves identically and prompts/skills port cleanly.
3. As a user, I want duplicate tool aliases (snake_case + PascalCase) collapsed to the single reference name, so that the tool list is unambiguous.
4. As a user, I want `/ctx_viz`, `/output-style`, `/reload-plugins`, `/autofix-pr`, `/terminalSetup` spelled as the reference spells them, so that documentation and help match.
5. As a user, I want a top-level `/plan` command (not only `/plan <action>` subcommands), so that entering plan mode matches the reference.
6. As a power user, I want a full hook system with the reference's lifecycle events (PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, UserPromptSubmit, SessionStart, SessionEnd, Stop, StopFailure, PreCompact, PostCompact, SubagentStart, SubagentStop, Notification, and the rest), so that my existing hook configs work.
7. As a power user, I want hooks configured in settings.json keyed by event with matcher + hooks arrays, so that configuration matches the reference shape.
8. As a power user, I want hook matchers using permission-rule syntax (e.g. `Bash(git *)`), so that I can scope hooks to specific tools and arguments.
9. As a power user, I want hooks to receive JSON on stdin and return `hookSpecificOutput` JSON on stdout, so that hook authoring is portable from Claude Code.
10. As a power user, I want exit-code 2 to mean "blocking error shown to the model" and other non-zero codes to mean "user error, continue", so that hook control flow matches.
11. As a power user, I want `command`, `prompt`, `http`, and `agent` hook types, so that I can run shells, LLM evals, webhooks, and verifier subagents as hooks.
12. As a power user, I want `async`/`asyncRewake`, `timeout`, `statusMessage`, and `once` hook options, so that background and one-shot hooks behave like the reference.
13. As a power user, I want `CLAUDE_ENV_FILE` and `watchPaths` support, so that hooks can export env for later tools and register files to watch.
14. As a security-conscious user, I want allow/deny/ask permission rules in `Tool(pattern)` syntax with wildcards, so that I can precisely govern what runs without prompts.
15. As a user, I want layered settings precedence (managed > policy > local > project > user > flag), so that org policy and project config compose like the reference.
16. As a user, I want permission modes default/acceptEdits/plan/bypassPermissions/dontAsk, so that I can pick the right autonomy level per session.
17. As a user, I want session "always-allow" memory, so that approving a tool once stops re-prompting within the session.
18. As a user, I want plan mode to gate tool execution and restore my prior mode on exit, so that planning is side-effect-free.
19. As a user, I want the permission prompt to show risk and let me edit tool arguments before approving, so that I can correct a call instead of rejecting it.
20. As a user, I want denial-based rule suggestions after repeated denials, so that I can codify my preferences quickly.
21. As a user, I want OS sandbox configuration (allowWrite/denyRead paths, allowed network domains), so that sandboxed execution matches the reference's controls.
22. As a user on a slow or overloaded API, I want exponential backoff with the reference's schedule, so that transient errors recover gracefully.
23. As a user, I want automatic fallback to a fallback model on overload (529/429), so that my session survives capacity issues.
24. As a user, I want reactive compaction when a request is too long (413), so that the conversation recovers instead of failing.
25. As a user, I want token-budget-aware auto-continuation with a nudge near the limit, so that long tasks continue sensibly.
26. As a user, I want tool-use summaries generated for prior turns, so that the model keeps context without re-reading full tool output.
27. As a user, I want `maxTurns` semantics distinct from tool-round limits, so that conversation length is bounded the way the reference bounds it.
28. As a user, I want to queue input mid-turn and have it folded in at turn end without an interruption message, so that I can steer without aborting.
29. As a user, I want thinking blocks preserved across the full turn trajectory, so that extended-thinking continuity matches the reference.
30. As a user, I want output styles injected into the system prompt, so that selecting a style actually changes behavior.
31. As an MCP user, I want SSE transport in addition to stdio/http/websocket, so that SSE servers connect.
32. As an MCP user, I want servers configured via settings scopes and `.mcp.json`, so that config matches the reference's sources.
33. As an MCP user, I want per-server enable/disable, so that I can turn servers off without removing them.
34. As an MCP user, I want MCP prompts surfaced as slash commands, so that server prompts are first-class.
35. As an MCP user, I want real elicitation (form/url) handling, so that servers can request input interactively.
36. As an MCP user, I want tool-description and large-result limits with disk spill, so that big outputs don't blow up context.
37. As an MCP user, I want ToolSearch deny-gating, so that disabled tools are filtered.
38. As a user, I want `@import` directives honored inside memory files (circular-safe), so that I can compose notes.
39. As a user, I want auto-extracted session memory written to MEMORY.md with a size cap, so that durable facts accumulate without manual saves.
40. As a user, I want an interactive `/memory` editor opening $EDITOR, so that editing memory matches the reference.
41. As a user, I want a freshness caveat injected for memories older than a day, so that stale facts are flagged.
42. As a user, I want `--add-dir` to load instructions from extra directories, so that monorepo and shared rulesets work.
43. As a user, I want a rewind picker to restore the conversation (and file state) to an earlier turn, so that I can undo a wrong direction.
44. As a user, I want a resume picker with fuzzy search across sessions, so that I can find and resume past work fast.
45. As a user, I want automatic compaction triggered by context pressure, so that I don't have to compact manually.
46. As a user, I want markdown session export in addition to JSON, so that I can share readable transcripts.
47. As a user, I want a plugin marketplace I can browse and install/update/uninstall from, so that plugins are usable end-to-end.
48. As a user, I want plugins to provide MCP servers, hooks, skills, and commands, so that plugins extend zcode like the reference.
49. As a user, I want LSP diagnostics injected into the agent's context, so that the model sees compiler/linter errors.
50. As a user, I want `/effort` with low/medium/high levels backed by thinking budgets, so that I can trade speed for depth.
51. As a user, I want scheduled tips and contextual suggestions, so that I discover features over time.
52. As a user, I want fullscreen overlays rendered (plan UI, task/todo panel, global search, quick-open, transcript pager), so that the interactive UX matches the reference.
53. As a user, I want @-mention file autocomplete and real slash-command completion, so that input assist matches the reference.
54. As a user, I want a structured diff viewer for edits, so that changes are readable like the reference.
55. As a user, I want the statusline to show cost, context usage, and rate-limit state, so that I can monitor my session.
56. As a user, I want the missing commands ported (`/ant-trace`, `/backfill-sessions`, `/btw`, `/desktop`, `/extra-usage`, `/good-claude`, `/mobile`, `/mock-limits`, `/passes`, `/perf-issue`, `/privacy-settings`, `/rate-limit-options`, `/reset-limits`, `/thinkback-play`), so that the command surface is complete.
57. As a user, I want `/voice`, `/teleport`, `/remote-setup`, `/remote-env` present as clearly-labeled stubs explaining the external dependency, so that nothing appears silently absent.
58. As a user relying on zcode's git workflow, I want the git tools, `/commit`, `/pr`, and `/pr-status` kept, so that the branch→commit→PR→merge flow still works.
59. As a user, I want our reference-less extras removed in one reviewable final commit, so that the surface matches the reference and I can veto specific deletions in that diff.
60. As a maintainer, I want each documented deviation (stub, best-effort substitute) recorded in the PRD and code, so that the gaps are auditable.
61. As a developer, I want the new permission, hook, memory, and loop logic extracted into pure deep modules with unit tests, so that correctness is verifiable in isolation.
62. As a developer, I want authentication left entirely untouched, so that our provider-key auth keeps working and no OAuth is introduced.
63. As a user, I want the SessionStart hook to fire on startup/resume/clear/compact with the right source, so that environment setup hooks run at the correct moments.
64. As a user, I want PreCompact/PostCompact hooks, so that I can inject custom compaction instructions.
65. As a user, I want config-change and file-change hooks, so that I can react to settings/file edits during a session.

## Implementation Decisions

**Driving artifact.** `docs/CC_PARITY_GAP_INVENTORY.md` is the authoritative gap list. Every specific
claim in it tagged VERIFY (e.g. the exact model-facing name of the Brief/SendMessage tool, whether a
listed "extra" has a reference equivalent under another name) must be confirmed against
`~/Downloads/claude-code-main/src` before acting; the survey is a lead, not gospel.

**Phasing.** Nine phases, ordered so dependencies land first. P2 (permissions) precedes P3 (hooks)
because hook matchers reuse the permission-rule parser. Each phase is a checkpoint commit + version
bump + release build + reinstall (per CLAUDE.md), so the suite stays green between phases.

**Deep modules (pure, isolated-testable, in `src/core/` unless noted), the single entry point pattern
from ADR 0004 preferred where a subsystem already has one:**

- P1: `tool_name_map` (internal name → reference-exact model-facing name; drives schema/registry), `command_canonical` (alias/spelling → canonical reference command name).
- P2: `permission_rule` (parse `Tool(pattern)` incl. wildcards/escapes/MCP `::` namespace; match against tool_name + tool_input), `settings_layers` (merge ordered layers with reference precedence), `permission_decision` (mode + rules + risk tier + session memory → allow/deny/ask + reason).
- P3: `hook_event` (event enum + per-event exit-code/blocking semantics + metadata), `hook_config` (settings.json `hooks` map → normalized specs across command/prompt/http/agent types), `hook_matcher` (delegates to `permission_rule`), `hook_io` (build per-event JSON stdin payload; parse `hookSpecificOutput` → typed decision). The fork/exec runner is integration glue in agent_runtime.
- P4: `backoff` (attempt → delay with reference base/cap/529-limit), `fallback_model` (error + config → next model or none), `reactive_compaction` (history + over-limit signal → reduced history via staged drain then snip), `budget_control` (token/task usage → continue/stop/nudge). Extend existing `turn_control`, `compaction`.
- P5: `mcp_output_limits` (truncate descriptions to cap; spill >100KB results to disk with pointer), `mcp_prompt_command` (MCP prompt definition → command spec). SSE transport + elicitation handler + ToolSearch deny-gating are integration in the mcp client.
- P6: `memory_import` (recursive `@import`/`@include` resolution, circular-safe, leaf-text-only), `memory_index` (MEMORY.md assemble + 200-line/25KB truncation + freshness caveat injection), `session_search` (fuzzy rank over labels/ids), `rewind` (history + target turn → truncated history), `session_export_md` (turns → markdown), `auto_compaction` (usage % + thresholds → trigger decision). The SessionMemory extraction subagent is integration.
- P7: `plugin_manifest` (parse manifest → spec incl. provided MCP/hooks/skills/commands + compatibility/isolation), `effort_levels` (level → thinking/token budget). Marketplace HTTP fetch/install and LSP-diagnostics injection are integration.
- P8: `diff_view` (old/new text → structured diff lines), `autocomplete` (prefix + context → ranked candidates for slash commands and @-mention files), extend `statusline` (segments incl. cost/context/rate-limit → width-fitted line). Overlay renderers (plan, task panel, global search, quick-open, transcript pager) are integration in `cli/repl_*`.
- P9: missing commands are mostly shallow handlers wired into the existing dispatcher; external-dep commands (`/voice`, `/teleport`, `/remote-setup`, `/remote-env`) ship as labeled stubs.

**Naming.** Reference-exact for model-facing tool names and user-facing command names; drop duplicate
aliases; keep internal Zig file/module names. Underscore/hyphen normalization accepts the reference
canonical spelling as primary.

**Removals.** Spare `GitCommit`/`GitDiff`/`GitLog`/`git_status`/`/commit`/`/pr`/`/pr-status`. Remove all
other reference-less extras (tools: `Copy`, `Delete`, `Move`, `HttpRequest`, `JsonQuery`, `ListDir`,
`OpenPR`, `RunTests`, `Stat`, `TaskPoll`, `TaskRun`, `TodoRead`; commands: `/advisor`, `/changelog`,
`/density`, `/errors`, `/features`, `/format`, `/insights`, `/lang`, `/mode`, `/preprocessor`,
`/prompt`, `/security-review`, `/whoami`, `/marketplace`, `/todos`, `/cd`, `/pwd`) as ONE final
reviewable commit. Renames (`/kairos`, `/loop`, `/dream`, `/brief`, `/worktree`, `/policy`, `/trust`,
`/ultraplan`, `/init`, `/skill`) are reconciled, not deleted.

**Deviations to stub + document:** voice (mic + STT), Chrome integration, remote/bridge/teleport/
coordinator (cloud), telemetry/analytics (phone-home), Yoga layout (our renderer substitutes), team
memory sync (cloud, best-effort). Each gets a code comment and a PRD/inventory note.

**Authentication:** untouched. No `/login`, `/logout`, `/oauth-refresh`, `/install-github-app`,
`/install-slack-app`, MCP OAuth, or token storage work. Existing provider-key auth is left as-is.

## Testing Decisions

Good tests assert external behavior through a module's public interface, not its internals: given
inputs, assert outputs/decisions; never reach into private state. This mirrors the deep-module tests
from PRD #532 (skill_types/skill_listing/skill_visibility) and #533 (provider_caps/turn_control/
compaction.microcompact), which feed fixed inputs and assert the returned value.

**Modules getting unit tests (all pure deep modules):** `tool_name_map`, `command_canonical`,
`permission_rule`, `settings_layers`, `permission_decision`, `hook_event`, `hook_config`,
`hook_matcher`, `hook_io`, `backoff`, `fallback_model`, `reactive_compaction`, `budget_control`,
`mcp_output_limits`, `mcp_prompt_command`, `memory_import`, `memory_index`, `session_search`,
`rewind`, `session_export_md`, `auto_compaction`, `plugin_manifest`, `effort_levels`, `diff_view`,
`autocomplete`, `statusline`.

**Test characteristics per module:** permission_rule (pattern match incl. wildcards/escapes/MCP
namespace, allow vs deny vs ask precedence); settings_layers (precedence ordering, override wins,
list-merge semantics); permission_decision (each mode × tier × rule × session-memory combination);
hook_io (round-trip a representative payload per event, parse each `hookSpecificOutput` variant,
exit-code mapping); reactive_compaction/memory_import/rewind (transform correctness + idempotence +
circular/edge inputs); backoff/fallback_model/budget_control/auto_compaction/effort_levels (boundary
decisions); diff_view/autocomplete/statusline (representative inputs → expected structured output +
width fitting).

**Integration glue verified manually** (not unit-tested in this PRD): MCP SSE transport, marketplace
HTTP, hook fork/exec round-trip, overlay rendering, SessionMemory extraction subagent, LSP-diagnostics
injection.

**Discovery:** every new pure module must be registered in the `src/main.zig` comptime test-discovery
block, or `zig build test` silently skips its tests (see wiki `test-discovery`). Acceptance per phase:
`zig build test` green, `zig fmt --check` clean, release built and installed with the `rm -f` fix.

## Out of Scope

- **Authentication** entirely: account OAuth, login/logout, token refresh/storage, MCP server OAuth, GitHub/Slack app install. Existing provider-key auth is neither reproduced-over nor modified.
- **True external-dependency parity:** functioning voice STT, the real Chrome extension protocol, live remote/bridge/teleport/coordinator cloud services, and outbound telemetry are NOT implemented; they ship as best-effort local stand-ins or labeled stubs.
- **Byte-for-byte UI identity:** we match behavior and rough content, not exact strings/spacing/colors/box-drawing; the Yoga/Ink layout engine is replaced by our renderer.
- **Internal name mirroring:** Zig file/module/function names are not renamed to mirror the reference tree.
- **Reference internals with no user-facing surface** (their React reconciler, native-ts addons beyond a layout substitute, build/migration tooling specific to their distribution).
- **Removing workflow-critical tooling:** git tools, `/commit`, `/pr`, `/pr-status` are explicitly retained.

## Further Notes

- This is a very large effort (multiple "L" phases). The user opted for one mega-PRD and `/goal it all`
  with no mid-way prioritization checkpoint; phases still land as independent checkpoint commits so the
  suite stays green and progress is reviewable.
- Prompt-mechanism (PRD #533), skill (PRD #532), and KAIROS parity are already shipped; this PRD does
  not redo them and should build on their modules (provider_caps, turn_control, compaction, skill_*).
- ADR 0004 (keep prompt modules separate, single entry point) applies to new subsystems: prefer one
  public entry per subsystem over many shallow ones.
- The final removal commit is the one destructive step; it is staged last and itemized so specific
  deletions can be vetoed from its diff before merge.
- Per the user's standing rules: no em/en dashes anywhere in code/text; never state unverified claims
  as facts; the epistemic-honesty system-prompt reminder stays.
