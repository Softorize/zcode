# Phase 2: Permission rule engine: deny-wins precedence, settings rules, glob/regex matcher, MCP wildcard, path-safety

## Overview

**What.** This phase rebuilds the heart of zcode's permission engine to match the
reference project's behavior-class precedence model and closes a set of
correctness, security, and UX gaps around it. The two load-bearing changes are
(1) flipping rule evaluation from "latest matching rule wins" to
"deny-always-wins, then ask, then allow" (gap permissions-01), and (2) adding a
bypass-immune path-safety guard for dangerous directories and files on edits
(gap permissions-03). Around those we add MCP server-level wildcard matching
(permissions-04), shared rule-content (`Tool(content)`) parsing with legacy
aliasing (permissions-11), additional-working-directory sandbox wiring
(permissions-05), systematic path-validation TOCTOU guards (permissions-16),
granular network domain allow/deny (permissions-07), shadow/unreachable-rule
detection (permissions-09), denial tracking (permissions-10), Agent(type) deny
rules (permissions-15), multi-destination + setMode/replaceRules persistence
(permissions-12), and a structured permission-decision debug taxonomy
(permissions-14).

**Why.** The current engine (`core/permission_rules.zig` `match()` at lines
178-189) iterates rules in reverse and returns the first match of ANY action
type. This is a real correctness divergence: a user who writes
`deny Bash(curl:*)` BEFORE `allow Bash(*)` gets ALLOW in zcode but DENY in the
reference. Security-wise, nothing today stops the model from auto-editing
`.git/config`, `~/.bashrc`, or `.claude/settings.json` (a documented code-exec
and exfil vector that the reference explicitly blocks bypass-immune). And the
TSV rule format is wire-incompatible with the reference `Tool(content)` rule
strings, so settings rules cannot round-trip.

**Dependencies.** Phase 1 (tool identifier reconciliation: `core/tool_name_map.zig`
canonical names, `core/permission_decision.zig` modes/outcomes). This phase
relies on canonical tool names being available at the permission-check call site
and on the `permission_decision.Mode`/`Outcome` types already present.

**Effort.** XL. Twelve gaps, two of them (permissions-01 deny-wins,
permissions-03 path-safety) are high-severity and touch the hot path in
`agent_tools.zig:executeToolCall`. The remainder are S/M and largely additive.

**Key architectural decisions made up front (state and apply, don't re-derive):**

1. **Keep the on-disk TSV format AND add a parallel `Tool(content)` string
   parser.** The reference stores rules as opaque `Tool(content)` strings; zcode
   stores them as structured TSV rows (`action / scope / tool / args_contains /
   source`). Rather than rip out the TSV store, we add
   `core/permission_rule_string.zig` (parser/serializer for `Tool(content)`)
   and teach `Rule` matching to understand a tool-wide vs content-keyed rule
   distinction. This preserves zcode's existing persisted rules and tests while
   giving us reference-compatible rule semantics.

2. **Behavior-class precedence is computed in one new function**
   `Store.decide()` that scans deny rules first (all of them, regardless of
   list position), then ask rules, then allow rules. The old `match()` stays for
   backward compatibility (the `/permissions explain` debug path uses it) but the
   hot path in `executeToolCall` switches to `decide()`.

3. **Path-safety is a separate pure module** `core/path_safety.zig` that the
   edit/write tools AND the permission gate both consult. It is bypass-immune:
   it returns "must prompt / blocked" even when `yolo_mode` or
   `bypassPermissions` is set, mirroring reference step 1g.

---

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| permissions-01 | Deny-always-wins vs latest-matching-rule-wins | high | M | Latest-wins (reverse-iterate, first match any action) in `permission_rules.zig:178-189`; no deny-first pass. |
| permissions-03 | Path-safety guard for dangerous dirs/files on edits | high | M | Missing. We have binary/device/dir/read-before-edit/mtime/secret/workspace checks but no DANGEROUS_DIRECTORIES/DANGEROUS_FILES list, no bypass-immune safetyCheck. |
| permissions-04 | MCP server-level wildcard rule matching | medium | S | `parseMcpToolName` exists in `tool_dispatch.zig:1045` but is NOT wired into `toolMatches`; only exact/literal-`*` matching. Note: zcode uses `mcp::server::tool` separators, not `mcp__server__tool`. |
| permissions-05 | additionalWorkingDirectories / --add-dir sandbox wiring | medium | M | `/add-dir` persists + injects context, but `sandbox.validateWorkspacePaths` checks only single cwd; extra dirs are not authorized. |
| permissions-07 | Sandbox network domain allow/deny config | medium | L | `egress_allowlist` + private-network opt-in present; missing deniedDomains, unix-socket toggle, proxy ports. |
| permissions-09 | Shadowed / unreachable rule detection | low | S | Missing entirely. No reachability analysis, no fix suggestions. |
| permissions-10 | Denial tracking with fallback-to-prompting limits | low | S | Missing. Only per-tool one-time session approval memory. |
| permissions-11 | Rule-content escaping / paren-aware parsing + legacy aliases | low | S | TSV sidesteps parse; `Tool(content)` syntax, escaping, and legacy aliasing in rule matching all absent. |
| permissions-12 | PermissionUpdate persistence to multiple destinations + setMode/replaceRules | medium | M | add/remove to single `rules.tsv`; no replaceRules, no directory updates, no setMode persistence, no source split. |
| permissions-14 | Permission explainer / decision debug info | low | S | `/permissions explain` + per-source attribution present; missing structured `PermissionDecisionDebugInfo` taxonomy and LLM risk side-query. |
| permissions-15 | Agent(agentType) deny rules to filter sub-agents | low | S | Missing. No agent-type matching in rules; no `filterDeniedAgents`. |
| permissions-16 | Path validation guards: tilde-variant / shell-expansion / UNC / glob-in-write / dangerous-removal | medium | M | Partial: null-byte, `..`, basic `~/`, symlink, device, root-delete, literal `rm -rf /`/`~`. Missing: `~user`/`~+`/`~-`, `$VAR`/`${}`/`$()`/`%VAR%`/`=cmd`, UNC, glob-in-write, full `isDangerousRemovalPath`. |

---

## Implementation tasks

> Convention reminders applied throughout: new modules live under `src/core/`
> (deep, pure where possible), are registered in the `comptime { _ = @import(...) }`
> block in `src/main.zig` so the custom test runner discovers their tests, and
> import the runtime via `@import("zcode_runtime")` (never a relative path) when
> they need `rt.io`/`rt.gpa`. Tests run under `tools/test_runner.zig`. Bump
> `.version` in `build.zig.zon` per the project rule. After build, `rm -f` the
> installed binary before `cp` (ad-hoc-signature footgun).

### Task 1 - permissions-11: `Tool(content)` rule-string parser + legacy aliasing (foundation)

**Goal.** Provide a reference-compatible parser/serializer for `Tool(content)`
rule strings with escaped parens, `Tool()`/`Tool(*)` tool-wide normalization,
and legacy tool-name aliasing, so all later tasks can speak the reference rule
vocabulary.

**Reference behavior + file:line.**
`src/utils/permissions/permissionRuleParser.ts:55-152`
(`escapeRuleContent`/`unescapeRuleContent`/`permissionRuleValueFromString`/
`permissionRuleValueToString`/`findFirstUnescapedChar`/`findLastUnescapedChar`)
and `permissionRuleParser.ts:21-33` (`LEGACY_TOOL_NAME_ALIASES`,
`normalizeLegacyToolName`). Note the reference's behavior: an unescaped `(`
not at a valid open position, content after the closing paren, or empty/`*`
content all collapse to a tool-wide rule.

**Target Zig files.**
- CREATE `src/core/permission_rule_string.zig`.
- EDIT `src/main.zig` comptime block: add `_ = @import("core/permission_rule_string.zig");`.
- REUSE `src/core/tool_name_map.zig` `canonical()` for the legacy alias step.
  Note: the reference aliases `Task -> Agent`, `KillShell -> TaskStop`,
  `AgentOutputTool/BashOutputTool -> TaskOutput`. zcode's `tool_name_map.canonical`
  already maps `MultiEdit -> Edit`, `file_read -> Read`, etc. It does NOT
  currently map `Task -> Agent` or `KillShell -> TaskStop`; add those two pairs
  to `tool_name_map.aliases` in this task (surgical addition, keeps a single
  alias table).

**Approach.**
1. Define `pub const RuleValue = struct { tool_name: []const u8, rule_content: ?[]const u8 }`.
   `rule_content == null` means a tool-wide rule.
2. `pub fn parse(allocator, rule_string) !RuleValue`:
   - Find first unescaped `(` (backslash-parity scan, port
     `findFirstUnescapedChar`). If none -> `{ tool_name = canonical(rule_string), rule_content = null }`.
   - Find last unescaped `)`. If missing, before the open, or not at end-of-string
     -> treat whole string as tool name (tool-wide).
   - Slice tool name (before `(`) and raw content (between parens). Empty tool
     name -> whole string is the tool name.
   - Raw content `""` or `"*"` -> tool-wide (`rule_content = null`).
   - Otherwise `rule_content = unescape(raw)`, tool name canonicalized via
     `tool_name_map.canonical`.
   - Allocator is needed because unescape produces a new owned string; return
     owned slices and document ownership. Provide `RuleValue.deinit(allocator)`.
3. `pub fn toString(allocator, value) ![]u8`: if `rule_content == null` return
   dup of `tool_name`; else `"{tool}({escaped})"`.
4. `escape`/`unescape`: port the exact ordering from the reference (escape
   backslashes first then parens; unescape parens first then backslashes).
5. Keep it pure: only `std` + allocator, no IO, no runtime singleton.

**Acceptance criteria.** Write tests in the new module:
- `parse("Bash")` -> `{ "Bash", null }`.
- `parse("Bash(npm install)")` -> `{ "Bash", "npm install" }`.
- `parse("Bash(python -c \"print\\(1\\)\")")` -> content `python -c "print(1)"`.
- `parse("Bash()")` and `parse("Bash(*)")` -> tool-wide (`rule_content == null`).
- `parse("Task(Explore)")` -> `{ "Agent", "Explore" }` (legacy alias applied to
  the tool name only, content preserved).
- `toString(parse(s))` round-trips for each of the above (escaping survives).
- `parse("(foo)")` -> tool-wide with tool name `"(foo)"` (malformed, no tool name).

**Test strategy.** `test` blocks in `core/permission_rule_string.zig`, run via
`/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test`. Use
`testing.allocator` so leaks fail the test.

**Risk / footguns.** Ownership: every parse/toString that allocates must have a
matching free in tests (`testing.allocator` is leak-checked by the custom
runner). Do not use `std.mem.replace` blindly for unescape - it does not handle
the backslash-parity rule; port the char-scan loops. Avoid em/en dashes in doc
comments.

**Size.** S.

---

### Task 2 - permissions-04: MCP server-level + glob tool matching

**Goal.** Make a rule whose tool is `mcp::server` match every tool from that
server, and `mcp::server::*` glob all of its tools, reusing the existing glob
matcher.

**Reference behavior + file:line.**
`src/utils/permissions/permissions.ts:238-269` (`toolMatchesRule` MCP branch):
a rule matches the whole tool when the rule has no content AND either the names
are equal OR `mcpInfoFromString(rule) !== null && mcpInfoFromString(tool) !== null
&& (ruleInfo.toolName === undefined || ruleInfo.toolName === '*') &&
ruleInfo.serverName === toolInfo.serverName`. Parsing helper:
`src/services/mcp/mcpStringUtils.ts:19-32` (`mcpInfoFromString`).

**zcode separator caveat (verified).** The reference uses `mcp__server__tool`;
zcode uses `mcp::server::tool` (see `tool_dispatch.zig:1045-1053`
`parseMcpToolName` and its tests at 1283-1286). Implement the matcher against
zcode's `mcp::` separator, not the reference `mcp__`.

**Target Zig files.**
- EDIT `src/core/permission_rules.zig` `toolMatches` (line 222-224).
- Add a small private `mcpInfo(name) ?struct { server, tool: ?[]const u8 }`
  helper in `permission_rules.zig` (do not import `tool_dispatch.zig` from a
  `core/` module - that would invert the dependency direction; duplicate the
  ~6-line parse, or lift `parseMcpToolName` into a tiny `core/mcp_name.zig` and
  have `tool_dispatch.zig` import it. Prefer the latter for single-source-of-truth).

**Approach.**
1. CREATE `src/core/mcp_name.zig` with
   `pub fn parse(name) ?struct { server: []const u8, tool: ?[]const u8 }`:
   strip `mcp::` prefix, split on first `::`. If there is no second `::`, the
   whole remainder is the server and `tool = null` (this is the "server-level"
   rule form `mcp::server`). If there is a `::`, server is before, tool is after
   (may itself contain `::`, join the rest - mirror `mcpInfoFromString`'s
   double-underscore handling). Empty server -> null.
   Register in `main.zig` comptime block. Update `tool_dispatch.zig` to import
   and use it (replace the local `parseMcpToolName` body, keep the `::server::tool`
   non-null-tool contract there - dispatch still requires a concrete tool).
2. In `permission_rules.zig` `toolMatches(pattern, tool)`:
   - Existing fast paths: `pattern == "*"` or `pattern == tool` -> true.
   - If the pattern parses as MCP and the tool parses as MCP:
     match when `pattern.server == tool.server` AND
     (`pattern.tool == null` OR `pattern.tool == "*"`).
   - Otherwise fall through to existing literal logic.
3. Because the rule's tool field is the only place MCP server-level patterns
   appear, this is a localized change to one function.

**Acceptance criteria.** Tests in `permission_rules.zig`:
- Rule tool `mcp::kali` matches tool `mcp::kali::nmap_scan` and `mcp::kali::sqlmap_scan`.
- Rule tool `mcp::kali` does NOT match `mcp::miro::create-board`.
- Rule tool `mcp::kali::*` matches `mcp::kali::nmap_scan`.
- Rule tool `mcp::kali::nmap_scan` matches only that exact tool.
- Non-MCP rule `Bash` still does NOT match `mcp::kali::nmap_scan`.

**Test strategy.** Add cases to the existing `permission_rules.zig` test block
and a dedicated `core/mcp_name.zig` test block. Confirm `tool_dispatch.zig`
tests (1283-1286) still pass after lifting the parser.

**Risk / footguns.** Do not let `mcp::server` (server-level) accidentally match a
plain `Bash` rule - guard the MCP branch behind "both parse as MCP". Watch the
`tool == null` vs `tool == "*"` distinction: `mcp::server` (no trailing `::`)
parses to `tool=null`; `mcp::server::*` parses to `tool="*"`. Both must match all
server tools.

**Size.** S.

---

### Task 3 - permissions-01: deny-always-wins behavior-class precedence (CORE)

**Goal.** Evaluate rules by behavior class - all deny rules first, then ask, then
allow - so a deny rule anywhere beats an allow rule regardless of file position.

**Reference behavior + file:line.**
`src/utils/permissions/permissions.ts:1169-1297`
(`hasPermissionsToUseToolInner` steps 1a deny, 1b ask, 2b allow) backed by
`permissions.ts:287-302` (`getDenyRuleForTool`/`getAskRuleForTool`) and
`permissions.ts:275-282` (`toolAlwaysAllowedRule`). Ordering: deny -> ask ->
tool-impl deny -> bypass -> allow. Content-keyed ask rules and safetyChecks are
bypass-immune (steps 1f/1g, lines 1238-1260).

**Target Zig files.**
- EDIT `src/core/permission_rules.zig`: add `pub fn decide(...)`.
- EDIT `src/agent_tools.zig` `executeToolCall` (lines 637-668): replace the
  single `rules.match()` switch with the new `decide()` result and integrate with
  `permission_decision.decide` (already present from Phase 1).
- EDIT `src/repl_commands.zig:2270,2322` precedence wording ("latest matching
  rule wins" -> "deny wins, then ask, then allow").

**Approach.**
1. Add to the `Rule` struct a way to tell tool-wide from content-keyed rules.
   Today `args_contains.len == 0` already means "any args" (tool-wide). Keep that
   convention; the reference distinction (`ruleContent === undefined`) maps to
   `args_contains.len == 0`. Where the reference checks "rule has no content" for
   whole-tool matching, zcode checks `args_contains.len == 0`.
2. Add `pub const DecideResult = struct { action: Action, match: Match }` and
   `pub fn decide(self, cwd, tool, args) ?DecideResult`:
   - First pass: iterate ALL rules in stored (forward) order; return the FIRST
     rule with `action == .deny` that matches `scope && tool && args`.
   - Second pass: same, first matching `.ask` rule.
   - Third pass: same, first matching `.allow` rule.
   - Return null if nothing matches.
   Forward order within a class matches the reference (`.find` returns the first
   in source-concatenation order). Keep `match()` (reverse, any-action) intact -
   `/permissions explain` and tests still use it; mark its doc comment to say it
   reports the "last-defined matching rule" for debugging, distinct from the
   precedence used at enforcement.
3. In `executeToolCall`, replace lines 637-668:
   ```
   if (ctx.permission_rules) |rules| {
       const rule_action: ?permission_rules_mod.Action =
           if (rules.decide(ctx.cwd, effective_name, args)) |d| d.action else null;
       // feed rule_action into permission_decision.decide alongside mode/tier/edit/session
       ...
   }
   ```
   But note the current code switches directly on the rule action and does not go
   through `permission_decision.decide`. Two options - pick the simpler that
   preserves current behavior for the non-rule path:
   - **Chosen approach:** keep the explicit switch but drive it off `decide()`'s
     action instead of `match()`'s. `.deny` -> blocked trace (deny wins). `.allow`
     -> run approved. `.ask` -> session-approved short-circuit, else prompt. This
     is the minimal change that fixes precedence without reworking the whole gate.
   - Defer full `permission_decision.decide` integration (mode interplay) - that
     is Phase 1's surface and out of scope here except for the deny-wins fix.
4. Update the `formatPermissionRuleReason` callers to use `decide()`'s `Match`.

**Acceptance criteria.** Write a test in `permission_rules.zig`:
- Add `deny Bash(curl:*)` THEN `allow Bash(*)` (deny first). `decide(...,"Bash",
  curl-args)` returns `.deny`. (Today `match()` would too, since deny is earlier;
  the real regression is the reverse order.)
- Add `allow Bash(*)` THEN `deny Bash(curl:*)`... that already denies under
  latest-wins, so the load-bearing case is: add `deny Bash(curl:*)` FIRST, then
  `allow Bash(*)` SECOND, and assert `decide` returns `.deny` while the OLD
  `match()` returns `.allow`. Encode both assertions to lock the divergence.
- Add `ask Bash(*)` and `allow Bash(ls:*)`: `decide` for `ls` returns... ask wins
  over allow per behavior class (reference 1b before 2b), so assert `.ask`.
- A pure-allow store still returns `.allow`.
- In `agent_tools.zig`, an integration-style test (or a focused unit test on the
  decision branch) proving a deny-first-then-allow store yields a `.denied`/
  `.blocked` `ToolTrace`.

**Test strategy.** Unit tests in `permission_rules.zig` for `decide()` ordering;
keep the existing `match()` tests green. Run full `zig build test`.

**Risk / footguns.** The current `match()` reverse iteration is relied upon by
the `/permissions explain` and round-trip tests at lines 321-389 - do NOT change
`match()`'s semantics, ADD `decide()`. The `agent_tools.zig` switch currently
treats `.allow` as immediate run and `.ask` with session-approval memory - keep
that exact behavior, only change the SOURCE of the action from `match` to
`decide`. Beware double-free of the `Match.rule` pointer - `decide` returns a
borrowed pointer into `store.rules.items`, same lifetime contract as `match`.

**Size.** M.

---

### Task 4 - permissions-15: Agent(agentType) deny rules

**Goal.** Let a deny rule `Agent(Explore)` block the `Explore` sub-agent from
being offered or spawned.

**Reference behavior + file:line.**
`src/utils/permissions/permissions.ts:304-343`
(`getDenyRuleForAgent` and `filterDeniedAgents`): a deny rule matches an agent
when `rule.ruleValue.toolName === "Agent"` and `rule.ruleValue.ruleContent ===
agentType`. `filterDeniedAgents` collects all Agent(content) deny contents into a
set and filters the agent list.

**Target Zig files.**
- EDIT `src/core/permission_rules.zig`: add
  `pub fn isAgentDenied(self, cwd, agent_type) bool` and
  `pub fn deniedAgentTypes(self, allocator, cwd) ![][]const u8` (or a callback
  iterator to avoid allocation).
- EDIT `src/agent_history.zig` (`activateAgentByNameImpl`) and
  `src/agent_runtime.zig` (`spawnChildAgent`) to consult it. Verify exact
  function names with grep before editing.
- Reuse Task 1's `permission_rule_string` semantics: the rule's `tool` is
  `"Agent"` and `args_contains` carries the agent type (content-keyed rule).

**Approach.**
1. `isAgentDenied(cwd, agent_type)`: scan rules; true if any `action == .deny`,
   scope matches `cwd`, `tool == "Agent"`, and `args_contains == agent_type`
   (exact match, not substring - agent type is an identity, not a pattern).
2. Wire into agent activation: when the model requests an agent by name/type,
   if `isAgentDenied` -> refuse with a directive message
   ("agent type 'Explore' is denied by a permission rule"), do not spawn.
3. Wire into the agent OFFER path (where available agents are listed for the
   model or `/agents`): filter out denied types so they are not advertised.
   Verify whether zcode has a single "available agents" list to filter; if the
   offer path is scattered, filter at the point of advertisement and at the spawn
   gate (defense in depth).

**Acceptance criteria.** Tests:
- A store with `deny Agent(Explore)` (global): `isAgentDenied("/repo","Explore")`
  is true, `isAgentDenied("/repo","Plan")` is false.
- Workspace-scoped `deny Agent(Explore)` only denies inside that workspace.
- A spawn attempt of a denied agent returns a blocked/denied trace (integration
  test in `agent_runtime` or a focused unit test on the gate).

**Test strategy.** Unit tests in `permission_rules.zig`; a spawn-path test in the
agent runtime test file. Run `zig build test`.

**Risk / footguns.** Use exact match on agent type, not the glob/substring
`argsMatch`. The reference matches `ruleContent === agentType` exactly. Confirm
the canonical tool name for the agent tool in zcode (`Agent` per
`tool_name_map.reference_names`) and the `Task -> Agent` alias added in Task 1.

**Size.** S.

---

### Task 5 - permissions-03: bypass-immune path-safety guard for dangerous dirs/files (SECURITY, CORE)

**Goal.** Block auto-edits/writes to dangerous directories (`.git`, `.vscode`,
`.idea`, `.claude`, `.zcode`) and dangerous files (`.gitconfig`, `.gitmodules`,
`.bashrc`, `.bash_profile`, `.zshrc`, `.zprofile`, `.profile`, `.ripgreprc`,
`.mcp.json`, `.claude.json`), with trailing-dot / DOS-device / case-insensitive
bypass guards, enforced even in yolo/bypass.

**Reference behavior + file:line.**
`src/utils/permissions/filesystem.ts:57-79` (`DANGEROUS_FILES`/
`DANGEROUS_DIRECTORIES`), `filesystem.ts:435-488`
(`isDangerousFilePathToAutoEdit`), `filesystem.ts:537-602`
(`hasSuspiciousWindowsPathPattern`: NTFS ADS, 8.3 short names `~\d`, long-path
prefixes, trailing `[.\s]+$`, DOS device suffix `\.(CON|PRN|AUX|NUL|COM[1-9]|
LPT[1-9])$`, three-dot components, UNC), `filesystem.ts:620-659`
(`checkPathSafetyForAutoEdit` checking original + symlink-resolved paths),
`filesystem.ts:90-92` (`normalizeCaseForComparison` -> lowercase always),
`filesystem.ts:456-468` (the `.claude/worktrees/` structural exception). Bypass-
immunity wiring: `permissions.ts:1144-1152` and `1252-1260` (safetyCheck returned
as `ask` survives bypass mode).

**Target Zig files.**
- CREATE `src/core/path_safety.zig` (pure: takes a path string and platform,
  returns a verdict). Register in `main.zig` comptime block.
- EDIT `src/tools/file.zig` `write()` (line 1104) and `edit()` (line 1335): call
  the guard early and return a clear blocked error when unsafe (so the tool path
  is protected directly).
- EDIT `src/agent_tools.zig` `executeToolCall`: add a bypass-immune safetyCheck
  pass for edit/write tools that runs BEFORE the yolo short-circuit, so a
  dangerous edit prompts/blocks even in yolo mode (mirroring reference 1g). This
  is the load-bearing "bypass-immune" requirement.

**Approach.**
1. `path_safety.zig`:
   - `const dangerous_dirs = [_][]const u8{ ".git", ".vscode", ".idea", ".claude", ".zcode" };`
     (add `.zcode` since zcode's own config dir is equally sensitive).
   - `const dangerous_files = [_][]const u8{ ".gitconfig", ".gitmodules", ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile", ".ripgreprc", ".mcp.json", ".claude.json", ".claude.toml" };`
   - `pub const Verdict = union(enum) { safe, dangerous_dir: []const u8, dangerous_file: []const u8, suspicious_pattern };`
   - `pub fn check(path) Verdict`:
     - `hasSuspiciousPattern(path)` first: `~` followed by a digit; trailing
       dot/space (`endsWith` any of '.'/' '); DOS device suffix (case-insensitive
       CON/PRN/AUX/NUL/COM1-9/LPT1-9 after a final dot); three-or-more
       consecutive dots as a path component; UNC (`\\` or `//` prefix). These are
       all-platform per the reference rationale (NTFS can mount on macOS/Linux).
     - Split on both `/` and `\`. For each segment, lowercase-compare against
       `dangerous_dirs`. Apply the `.claude` -> next segment `worktrees`
       structural exception (skip that one `.claude`, keep checking others).
     - Lowercase-compare the final segment against `dangerous_files`.
   - Keep it allocation-free: lowercase-compare via a small `eqlIgnoreCaseAscii`
     helper (do not allocate a lowercased copy; `std.ascii.eqlIgnoreCase` exists).
2. Symlink dimension: the reference checks BOTH the literal path and the
   symlink-resolved path. zcode already resolves symlinks for workspace
   containment in `sandbox.zig:resolvedOrJoinedPathWithin`. For path-safety, also
   run `check()` against the realpath when the file exists. To avoid pulling IO
   into a pure module, expose `path_safety.check(path)` (pure) AND a thin
   `path_safety.checkResolved(allocator, cwd, path)` in the tool layer (or in a
   non-pure helper inside `file.zig`) that resolves and re-checks. Keep the pure
   core testable; the IO wrapper lives where IO already lives.
3. Tool-level enforcement in `file.zig`: near the top of `write()` and `edit()`
   (after the device-path checks, before atomic write), call the guard. On
   `dangerous_dir`/`dangerous_file`/`suspicious_pattern`, return a descriptive
   error (e.g. `error.PathBlockedBySafetyGuard`) with a message routed through the
   existing error-to-output mapping so the model sees "edit to <path> blocked:
   sensitive file/dir; requires explicit user approval".
4. Bypass-immune gate in `agent_tools.zig`: for edit/write tool names (reuse
   `approval_mod.isEditTool` / the existing write-tool name set), extract the path
   arg (reuse `sandbox.extractArg`-style logic - that function is private to
   `sandbox.zig`; either make a shared `core/arg_extract.zig` or duplicate the
   minimal key lookup for `path`/`file_path`). If unsafe, force an approval prompt
   regardless of `yolo_mode`/bypass: this is the only place yolo does NOT win.
   Place this check BEFORE the `sandbox_mod.authorizeToolYolo` yolo short-circuit
   at line 615 so yolo cannot skip it. When non-interactive, block (cannot prompt).

**Acceptance criteria.** Tests in `path_safety.zig`:
- `check("src/.git/config")` -> dangerous_dir `.git`.
- `check("/home/u/.bashrc")` -> dangerous_file `.bashrc`.
- `check(".claude/settings.json")` -> dangerous_dir `.claude`.
- `check(".claude/worktrees/x/foo.zig")` -> safe (structural exception).
- `check(".CLAUDE/Settings.json")` -> dangerous_dir (case-insensitive).
- `check(".git.")` and `check(".bashrc ")` -> suspicious_pattern (trailing dot/space).
- `check("settings.json.PRN")` -> suspicious_pattern (DOS device).
- `check("\\\\server\\share\\x")` -> suspicious_pattern (UNC).
- `check("src/main.zig")` -> safe.
And a behavioral test in `agent_tools.zig`: an Edit to `.bashrc` with
`yolo_mode = true` and `interactive = false` produces a blocked `ToolTrace`
(yolo did NOT bypass).

**Test strategy.** Pure tests in `path_safety.zig`; one bypass-immunity test in
`agent_tools.zig`. Run `zig build test`. Optional manual: `zcode` in a repo,
attempt `Edit .git/config`, confirm prompt/block.

**Risk / footguns.** Do NOT lowercase-allocate per segment (hot path on every
edit) - use `std.ascii.eqlIgnoreCase`. The `.claude/worktrees/` exception is
load-bearing (zcode stores worktrees there too); without it, legitimate worktree
edits break. Place the bypass-immune check before the yolo short-circuit or it is
useless. Returning a hard error from `file.zig` vs prompting in `agent_tools.zig`:
the tool-level guard is the floor (always blocks); the gate-level guard adds the
"prompt even in yolo" behavior. Keep both - the reference treats safetyCheck as
`ask` (promptable) not hard-deny, so the gate prompts; the file-tool floor is
zcode defense-in-depth for direct callers.

**Size.** M.

---

### Task 6 - permissions-16: systematic path-validation TOCTOU guards

**Goal.** Reject tilde-user variants, shell-expansion syntax, UNC paths, glob
patterns in write/create operations, and dangerous removal targets across all
file-tool paths.

**Reference behavior + file:line.**
`src/utils/permissions/pathValidation.ts:373-485` (`validatePath`):
reject UNC (`containsVulnerableUncPath`), reject `cleanPath.startsWith('~')` after
`expandTilde` already handled `~`/`~/` (so only `~user`/`~+`/`~-`/`~N` remain),
reject any `$`/`%` or leading `=`, reject glob patterns in write/create.
`pathValidation.ts:331-367` (`isDangerousRemovalPath`): `*` or `*/`-suffix,
`/`, Windows drive root, homedir, direct children of `/`.

**Target Zig files.**
- EDIT `src/core/path_utils.zig`: add `pub fn hasShellExpansion(path) bool`,
  `pub fn hasTildeVariant(path) bool`, `pub fn isUncPath(path) bool`,
  `pub fn hasGlobMeta(path) bool` (pure helpers, no IO).
- CREATE or EXTEND a removal guard: add `pub fn isDangerousRemovalPath(allocator, path) bool`
  to `src/tools/fs_extra.zig` (it already has the root/workspace delete guards
  at lines 76-87) OR to `core/path_utils.zig` if homedir resolution is threaded
  in. Homedir needs `path_utils.getHomeDir` (line 132) which uses the runtime;
  keep `isDangerousRemovalPath` in the tool layer where IO/home lookup is allowed,
  and a pure `isDangerousRemovalPathPure(path, home)` core helper it delegates to.
- EDIT `src/tools/file.zig` `write()`/`edit()` and `src/tools/fs_extra.zig`
  delete/move/copy to call the new guards.

**Approach.**
1. After quote-strip and `~`/`~/` expansion (file.zig already expands `~/` at
   1819-1834), check:
   - `hasTildeVariant`: path still starts with `~` (i.e. `~user`/`~+`/`~-`).
     Reject.
   - `hasShellExpansion`: contains `$` or `%`, or starts with `=`. Reject.
   - `isUncPath`: starts with `\\` or `//`. Reject.
   - `hasGlobMeta`: contains `*`, `?`, `[` - reject ONLY for write/create
     operations (not read), per the reference. Read tools may legitimately glob.
2. `isDangerousRemovalPath`: collapse `\\`/`/` runs to `/`; true if path is `*`
   or ends `/*`; if normalized is `/`; if Windows drive root/child; if equals
   homedir; if parent dir is `/` (direct child of root: `/usr`, `/etc`, `/tmp`).
   Wire into `fs_extra.zig` delete/`rm` path before unlink.
3. These are guards, not approvals: return a descriptive `error.PathRejected...`
   that maps to a model-readable message. Match the existing error-message style
   in file.zig.

**Acceptance criteria.** Tests (mostly pure in `path_utils.zig`):
- `hasTildeVariant("~root/.ssh/id_rsa")` true; `hasTildeVariant("/home/u/x")` false;
  `hasTildeVariant("~/x")` should be FALSE only after expansion - test the helper
  on the post-expansion string, document that ordering.
- `hasShellExpansion("$HOME/x")`, `("${VAR}/x")`, `("$(cmd)")`, `("%TEMP%\\x")`,
  `("=rg")` all true; `("/plain/path")` false.
- `isUncPath("\\\\server\\share")` and `("//server/share")` true.
- `hasGlobMeta("/dir/*.txt")` true, `("/dir/file.txt")` false.
- `isDangerousRemovalPathPure("*", home)`, `("/dir/*", home)`, `("/", home)`,
  `("/usr", home)`, `(home, home)` true; `("/repo/build", home)` false.
- Behavioral: `write(... path="$HOME/x" ...)` returns an error; `delete(... "/usr")`
  rejected.

**Test strategy.** Pure helper tests in `path_utils.zig`; removal-guard tests in
`fs_extra.zig`; one or two write/delete behavioral tests using `tmpDirCwd`. Run
`zig build test`.

**Risk / footguns.** Ordering matters: expand `~/` and strip quotes BEFORE
checking `hasTildeVariant`, or you reject legitimate `~/foo`. Do not reject globs
on read operations (Glob/Grep rely on them). Homedir comparison needs the real
home; `tmpDirCwd` tests must pass an explicit `home` arg to the pure variant so
they do not depend on the test process's `$HOME`. The CLAUDE.md note about
`std.fs.path.relative` taking 5 args is not relevant here, but do use the
`core/path_utils` helpers rather than reinventing.

**Size.** M.

---

### Task 7 - permissions-05: additionalWorkingDirectories sandbox wiring

**Goal.** Make file operations on paths inside additionally-registered
directories (`/add-dir`) pass sandbox authorization, instead of failing because
only the single cwd is checked.

**Reference behavior + file:line.**
`src/utils/sandbox/sandbox-adapter.ts:299` (`allowWrite.push(...additionalDirs)`),
`PermissionUpdate.ts:122-137` (`addDirectories`), and the permission context's
`additionalWorkingDirectories` map; `pathInAllowedWorkingPath` treats them as
in-bounds.

**Target Zig files.**
- EDIT `src/core/sandbox.zig`: add an additional-directories parameter to the
  authorization path. Add
  `pub fn authorizeToolYoloDirs(profile, cwd, extra_dirs: []const []const u8, tool_name, args, yolo_mode) Decision`
  and have `authorizeToolYolo` delegate with an empty slice (keep the existing
  signature for current callers). `validateWorkspacePaths` and
  `pathWithinWorkspace` gain an `extra_dirs` arg (a path is in-bounds if it is
  within cwd OR within any extra dir).
- EDIT `src/agent_tools.zig` `ToolExecContext` (lines 452-478): add
  `additional_directories: []const []const u8 = &.{}`.
- EDIT the call site at `agent_tools.zig:615` to pass
  `ctx.additional_directories`.
- EDIT `src/agent_runtime.zig` where `ToolExecContext` is constructed
  (around line 2854): load via `workspace_dirs.load(allocator)` once per session
  (or cache) and pass the slice. Free with `workspace_dirs.freeList` on teardown.

**Approach.**
1. Generalize `pathWithinWorkspace(cwd, raw_path)` to
   `pathWithinAnyRoot(roots: []const []const u8, raw_path)` and have the single-cwd
   form call it with `&.{cwd}`. The symlink-resolution logic
   (`resolvedOrJoinedPathWithin`) loops over roots; in-bounds if ANY root contains
   the resolved path.
2. `validateWorkspacePaths(cwd, extra_dirs, args)`: for each path-bearing key,
   in-bounds if within cwd OR any extra dir.
3. Thread `additional_directories` from the runtime. `workspace_dirs.load`
   returns owned `[][]u8`; the runtime owns the lifetime for the session. The
   context borrows the slice (do not free inside the tool call).

**Acceptance criteria.** Tests in `sandbox.zig`:
- `authorizeToolYoloDirs("workspace-write", "/repo", &.{"/sibling"}, "file_read",
  "path=/sibling/x.zig", false)` -> allowed.
- Same without the extra dir -> blocked.
- A path outside both cwd and extra dirs -> blocked.
- Symlink test extended: extra dir is honored, but a symlink escaping ALL roots
  is still blocked.

**Test strategy.** Extend `sandbox.zig` tests (model on the existing
"workspace-write blocks symlinked parent" test using `tmpDirPath`). Run
`zig build test`.

**Risk / footguns.** Lifetime: the extra-dir slice must outlive the tool call;
load once in the runtime, free on session end (`workspace_dirs.freeList`). Keep
the old `authorizeToolYolo` signature working (default empty slice) so the many
existing tests and call sites do not churn. Do not allocate per-call inside the
sandbox - pass the already-loaded slice.

**Size.** M.

---

### Task 8 - permissions-12: PermissionUpdate persistence (setMode/replaceRules + destinations)

**Goal.** Support `replaceRules` (bulk replace per behavior), `addDirectories`/
`removeDirectories`, and `setMode`/`defaultMode` persistence, with a destination
model richer than a single `rules.tsv`.

**Reference behavior + file:line.**
`src/utils/permissions/PermissionUpdate.ts:55-353` (`applyPermissionUpdate`:
setMode 60-67, addRules 69-95, replaceRules 97-120, addDirectories 122-137,
removeRules 139-..; plus `persistPermissionUpdate` 244-265 persisting
`additionalDirectories` and `defaultMode`). Update types in
`PermissionUpdateSchema.ts:42-78`. Destinations: userSettings / projectSettings /
localSettings (+ in-memory session/cliArg).

**Target Zig files.**
- EDIT `src/core/permission_rules.zig`: add
  `pub fn replaceRules(self, action: Action, scope, source_label, new_rules: []const RuleSpec) !void`
  (remove all rules of that action+source, append the new set).
- EDIT `src/repl_commands.zig` `runPermissionsCommand` (line 2258): add
  subcommands `/permissions replace`, `/permissions mode <mode>`,
  `/permissions add-dir`/`/permissions remove-dir` wrappers (or document that
  `/add-dir` remains the directory front-end and this task only wires its
  persistence into the permission-context view).
- For setMode persistence: zcode keeps `approval_mode` in `config.toml`
  (`config.zig:26,149`). The reference persists `defaultMode` into settings. Wire
  `/permissions mode <mode>` to update `config.approval_mode` and persist via the
  existing config save path (verify the config write helper).

**Approach.**
1. Decide the destination model. The reference's five sources collapse, for
   zcode, to: global (`~/.zcode/permissions/rules.tsv`) and workspace (scope-
   tagged rows in the same file). Do NOT invent a 5-file split now - that is a
   larger settings-loader change tracked elsewhere. Scope this task to:
   `replaceRules`, `mode` persistence, and directory updates routed through the
   existing `workspace_dirs` store. Document the source-split deferral explicitly.
2. `replaceRules(action, scope, label, specs)`: iterate and remove every rule
   matching `(action, scope, source_label)`, then append the new specs, then
   persist via the existing `saveToFile`/`reloadFromFile`.
3. `/permissions mode <mode>`: validate against `permission_decision.modeFromString`
   / `config.isKnownApprovalMode`, set `runtime.cfg.approval_mode`, persist config.
4. Directory updates: `/permissions add-dir`/`remove-dir` delegate to
   `workspace_dirs.add`/`workspace_dirs.remove` (already implemented) so the
   directory list is a single source of truth shared with sandbox wiring (Task 7).

**Acceptance criteria.** Tests:
- `replaceRules(.allow, .global, "user", &.{...two specs...})` after a store that
  had three allow rules -> exactly the two new allow rules remain (other actions
  untouched), survives save/reload round-trip.
- `/permissions mode acceptEdits` updates `cfg.approval_mode` and the value
  persists across a config reload (config test or repl_commands test).
- `/permissions add-dir /tmp/x` adds to the workspace-dirs store (reuse existing
  workspace_dirs tests; just confirm the command routes there).

**Test strategy.** Unit test `replaceRules` in `permission_rules.zig`; a
config-persistence test for mode; lean on existing `workspace_dirs` tests for the
directory path. Run `zig build test`.

**Risk / footguns.** `replaceRules` must free the removed rules
(`Rule.deinit`) - reuse `removeAt` semantics. The "five destinations" reference
model is intentionally NOT fully replicated here (see Out-of-scope). Confirm the
config-save helper exists and is callable from the REPL before wiring mode
persistence; if not, fall back to documenting that mode persists only for the
session and file an out-of-scope note.

**Size.** M.

---

### Task 9 - permissions-09: shadowed / unreachable rule detection

**Goal.** Flag allow rules made unreachable by a tool-wide deny (severe) or
tool-wide ask rule, with a fix suggestion, surfaced via `/permissions` and
`/doctor`.

**Reference behavior + file:line.**
`src/utils/permissions/shadowedRuleDetection.ts:111-147`
(`isAllowRuleShadowedByAskRule`), `:160-184` (`isAllowRuleShadowedByDenyRule`),
`:193-234` (`detectUnreachableRules`). A content-keyed allow rule is shadowed if a
tool-wide ask/deny rule for the same tool exists (deny first, more severe).

**Target Zig files.**
- CREATE `src/core/shadow_detection.zig` (pure: takes the rule list, returns a
  list of `{ shadowed_index, shadower_index, kind: deny|ask }`). Register in
  `main.zig` comptime block.
- EDIT `src/repl_commands.zig`: add `/permissions list` warnings and a
  `/permissions lint` subcommand; surface counts in `/doctor`.

**Approach.**
1. Reuse the tool-wide vs content-keyed distinction
   (`args_contains.len == 0` == tool-wide). For each allow rule WITH content,
   find a tool-wide deny rule for the same tool -> shadowed (deny, severe);
   else a tool-wide ask rule for the same tool -> shadowed (ask).
2. Return structured results (indices + kind) so the REPL can format
   "rule #N (allow Bash(ls:*)) is blocked by tool-wide deny Bash from <source>;
   fix: remove the allow rule or narrow the deny".
3. `/permissions lint` prints the report; `/permissions list` appends a short
   "N unreachable rule(s) - run /permissions lint" hint.

**Acceptance criteria.** Tests in `shadow_detection.zig`:
- `allow Bash(ls:*)` + tool-wide `deny Bash` -> one shadow result, kind deny.
- `allow Bash(ls:*)` + tool-wide `ask Bash` -> one shadow result, kind ask.
- Tool-wide `allow Bash` is never reported (only content-keyed allows).
- No shadowers -> empty result.
- Deny takes precedence over ask when both tool-wide rules exist (kind deny).

**Test strategy.** Pure tests in the new module; a smoke test of the REPL
formatting. Run `zig build test`.

**Risk / footguns.** This is meaningful ONLY after Task 3 (deny-wins precedence)
- the "deny shadows allow" claim is false under latest-wins. Sequence Task 9
after Task 3. Scope is tool-wide shadowers only (the reference also only handles
tool-wide shadowers). Skip the Bash-sandbox-auto-allow exception
(`shadowedRuleDetection.ts:135-144`) - zcode has no sandbox-auto-allow setting;
note the simplification.

**Size.** S.

---

### Task 10 - permissions-10: denial tracking with fallback-to-prompting

**Goal.** Track consecutive (>=3) and total (>=20) auto-denials and fall back to
interactive prompting once a limit is hit.

**Reference behavior + file:line.**
`src/utils/permissions/denialTracking.ts:7-45` (`DENIAL_LIMITS`
`{maxConsecutive:3, maxTotal:20}`, `createDenialTrackingState`, `recordDenial`,
`recordSuccess`, `shouldFallbackToPrompting`).

**Target Zig files.**
- CREATE `src/core/denial_tracking.zig` (pure state machine). Register in
  `main.zig` comptime block.
- EDIT `src/agent_runtime.zig` to hold a `DenialTrackingState` per session and,
  in the auto-deny branches of the tool gate, call `recordDenial`/`recordSuccess`
  and, when `shouldFallbackToPrompting`, switch that tool call to interactive
  prompting instead of silent deny.

**Approach.**
1. Port the struct and three functions verbatim (trivial integer arithmetic).
2. Identify the auto-deny site. In zcode this maps to the
   `permission_decision`-driven auto-deny / classifier-deny path. The summary
   notes `core/messages.zig:102-104` has `isClassifierDenial`. Record a denial
   when a tool is auto-denied (not user-denied), record success when a tool runs.
   When the limit trips, escalate that decision from "deny" to "ask" (prompt).
3. Keep it conservative: only escalate when interactive (a prompt is possible);
   in non-interactive runs the fallback is a no-op (still deny) - document this.

**Acceptance criteria.** Tests in `denial_tracking.zig`:
- Fresh state: not fallback.
- Three consecutive `recordDenial` -> `shouldFallbackToPrompting` true.
- `recordSuccess` resets consecutive (but not total); after reset, not fallback
  until either limit again.
- 20 total denials (with successes interspersed so consecutive never hits 3) ->
  fallback true on total.

**Test strategy.** Pure tests in the module. The runtime integration is small;
add one focused test if the gate is unit-testable, otherwise document manual
verification. Run `zig build test`.

**Risk / footguns.** This gap is explicitly low-value without the classifier
(see its notes). Implement the pure state machine and the minimal runtime hook;
do not build classifier infrastructure here. Ensure the fallback only fires in
interactive sessions.

**Size.** S.

---

### Task 11 - permissions-07: granular network domain allow/deny (deniedDomains, sockets, proxy)

**Goal.** Extend the egress policy from allow-only to also support an explicit
deny list (deniedDomains), with deny taking precedence, and stub the unix-socket
/ proxy-port config knobs.

**Reference behavior + file:line.**
`src/utils/sandbox/sandbox-adapter.ts:172-372` (`convertToSandboxRuntimeConfig`
building `network.{allowedDomains, deniedDomains, allowUnixSockets,
allowLocalBinding, httpProxyPort, socksProxyPort}`), `:152-157`
(`shouldAllowManagedSandboxDomainsOnly`).

**Target Zig files.**
- EDIT `src/core/egress.zig`: extend `Policy` (line 26) with a denied-domains
  list; `checkUrl` (line 64) returns deny when a host matches a denied pattern,
  evaluated BEFORE the allow check (deny wins, consistent with permissions-01
  philosophy).
- EDIT `src/core/config.zig`: add `egress_denylist: []u8` (CSV, same format as
  `egress_allowlist` at line 64) and optional `egress_unix_sockets: bool` /
  `egress_http_proxy_port` / `egress_socks_proxy_port` (the latter three may be
  config-only placeholders this phase; see Out-of-scope).
- EDIT `src/core/egress.zig` `configureRuntimePolicy` (line 54) to accept the
  denylist CSV.
- Wire at `src/main.zig` (around the existing managed-config integration at
  489-491) to pass the denylist.

**Approach.**
1. Reuse the existing wildcard-suffix matcher (`*.anthropic.com` style) for both
   allow and deny lists.
2. `checkUrl`: parse host; if it matches any denied pattern -> deny; else apply
   the existing allow logic.
3. Unix-socket / proxy knobs: add config fields and validation, but actual
   enforcement (binding to a proxy, allowing unix sockets in the shell sandbox) is
   a sandbox-backend feature beyond this phase. Add the fields, validate them, and
   document the enforcement deferral. Do not claim enforcement that does not
   exist (CLAUDE.md: no guesses-as-facts).

**Acceptance criteria.** Tests in `egress.zig`:
- With denylist `evil.com`: `checkUrl("https://evil.com/x")` denies even if the
  allowlist is empty/`*`.
- Deny wins over allow: allowlist `*`, denylist `evil.com` -> `evil.com` denied,
  `good.com` allowed.
- Wildcard suffix on denylist: `*.evil.com` denies `a.evil.com`.
- Existing allow-only tests stay green.
- Config validation accepts a well-formed denylist, rejects malformed.

**Test strategy.** Unit tests in `egress.zig` and `config.zig`. Run
`zig build test`. Manual: configure denylist, attempt WebFetch to a denied host.

**Risk / footguns.** Keep deny-before-allow ordering. The proxy/unix-socket knobs
are config placeholders; do NOT write enforcement code that silently no-ops while
looking active. The private-network plaintext opt-in
(`egress_allow_private_network_plaintext`, config.zig:65) already exists - leave
it.

**Size.** L (mostly the config surface + careful scoping of what is enforced vs
deferred).

---

### Task 12 - permissions-14: structured permission-decision debug taxonomy

**Goal.** Aggregate the decision factors (rule / mode / hook / safetyCheck /
sandboxOverride / workingDir) into one structured reason taxonomy surfaced by
`/permissions explain`, replacing scattered ad-hoc strings.

**Reference behavior + file:line.**
`src/utils/permissions/permissions.ts:137-205` (`createPermissionRequestMessage`
switching on `decisionReason.type`: hook / rule / subcommandResults /
permissionPromptTool / sandboxOverride / workingDir / safetyCheck / mode /
asyncAgent), and `components/permissions/PermissionDecisionDebugInfo.tsx`.

**Target Zig files.**
- CREATE `src/core/permission_reason.zig`: a `Reason` tagged union
  (`rule`, `mode`, `hook`, `safetyCheck`, `sandboxOverride`, `workingDir`,
  `policyBlocked`, `agentPolicy`, `other`) plus a `format` that renders the
  reference-style message. Register in `main.zig` comptime block.
- EDIT `src/agent_tools.zig`: have the gate produce a `Reason` and route it
  through `formatPermissionRuleReason` (line 480) / the blocked-trace output.
- EDIT `src/repl_commands.zig` `explainPermissionRule` (line 2393): print the
  structured reason taxonomy.

**Approach.**
1. Define the union mirroring the reference reason types relevant to zcode (drop
   classifier/subcommandResults/permissionPromptTool/asyncAgent which depend on
   features not in this phase; keep rule/mode/hook/safetyCheck/sandboxOverride/
   workingDir/policyBlocked/agentPolicy/other).
2. `format(allocator, tool_name, reason) ![]u8` produces messages like the
   reference (e.g. rule: "Permission rule '<ruleString>' from <source> requires
   approval for this <tool> command"; mode: "Current permission mode (<mode>)
   requires approval..."; safetyCheck/other: pass-through reason).
3. Wire the existing decision points to construct the right `Reason` variant.
   Skip the LLM risk side-query (`permissionExplainer.ts`) - explicitly out of
   scope (see Out-of-scope); it depends on a side-model query path zcode does not
   have here.

**Acceptance criteria.** Tests in `permission_reason.zig`:
- `format("Bash", .{ .mode = .plan })` contains "permission mode" and "plan".
- `format("Edit", .{ .safetyCheck = "sensitive file" })` passes the reason
  through.
- `format("Bash", .{ .rule = ... })` contains the rule string and source.
- `/permissions explain Bash "curl ..."` prints the taxonomy variant for the
  matched rule (smoke test).

**Test strategy.** Pure tests in the module; a smoke test of `/permissions
explain`. Run `zig build test`.

**Risk / footguns.** This is a refactor of how reasons are represented - keep the
existing user-visible strings stable where tests assert on them (grep for the
current messages in repl_commands and agent_tools tests before changing). Do NOT
build the LLM risk explainer. Avoid em/en dashes in generated messages.

**Size.** S.

---

## Verification

Build and install per CLAUDE.md (mandatory after every change):

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
```

(`rm -f` first to dodge the macOS ad-hoc-signature SIGKILL footgun.)

Full test suite (custom runner prints `RUN: <name>` per test for hang
diagnostics):

```
/Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
```

Bump `.version` patch in `build.zig.zon` before building.

**Per-gap proof:**

- permissions-01: new `permission_rules.zig` `decide()` tests show
  deny-first-then-allow returns `.deny` while legacy `match()` returns `.allow`;
  an `agent_tools.zig` test yields a blocked `ToolTrace` for that ordering.
- permissions-03: `path_safety.zig` tests cover all dangerous dirs/files, the
  `.claude/worktrees` exception, case-insensitivity, trailing-dot, DOS-device,
  UNC; an `agent_tools.zig` test proves an Edit to `.bashrc` is blocked even with
  `yolo_mode = true`. Manual: in a git repo, attempt to edit `.git/config`.
- permissions-04: `permission_rules.zig` tests for `mcp::server` and
  `mcp::server::*` matching; `tool_dispatch.zig` MCP tests still pass.
- permissions-05: `sandbox.zig` tests show a path inside an extra dir is allowed
  and outside-all is blocked; symlink-escape still blocked.
- permissions-07: `egress.zig` tests show deny-wins over allow and wildcard deny.
- permissions-09: `shadow_detection.zig` tests flag content-keyed allows shadowed
  by tool-wide deny/ask; `/permissions lint` prints them.
- permissions-10: `denial_tracking.zig` tests for the 3-consecutive / 20-total
  thresholds and consecutive reset.
- permissions-11: `permission_rule_string.zig` parse/toString round-trip tests
  incl. escaped parens and `Task -> Agent` aliasing.
- permissions-12: `replaceRules` round-trip test; `/permissions mode` persistence
  test.
- permissions-14: `permission_reason.zig` format tests; `/permissions explain`
  smoke test.
- permissions-15: `permission_rules.zig` `isAgentDenied` tests; a denied-agent
  spawn yields a blocked trace.
- permissions-16: `path_utils.zig` pure-helper tests + write/delete behavioral
  tests.

**Manual end-to-end checks** (run the installed binary):
- `/permissions add deny Bash curl` then `/permissions add allow Bash` then
  `/permissions explain Bash "curl evil.com"` -> reports deny wins.
- `/permissions lint` after adding `allow Bash(ls:*)` plus tool-wide `deny Bash`
  -> reports the unreachable allow.
- Attempt an edit to `~/.bashrc` -> blocked/prompted even in a yolo session.

---

## Out-of-scope / deferred notes

- **Full five-source destination model (userSettings / projectSettings /
  localSettings / policySettings / cliArg).** This phase keeps the global +
  workspace-scoped single `rules.tsv` model and adds replaceRules/mode/dir
  persistence on top. The reference's per-source settings-file split is a larger
  settings-loader change tracked separately (relates to permissions-02, which is
  not in this phase's gap set).
- **LLM-generated risk explanation (`permissionExplainer.ts`).** Requires a
  side-model query path; deferred. permissions-14 here delivers the structured
  reason taxonomy only.
- **Classifier / auto-mode loop.** permissions-10's denial tracking is
  implemented as a pure state machine plus a minimal interactive-fallback hook;
  the broader classifier (`classifierDecision`, `yoloClassifier`,
  `TRANSCRIPT_CLASSIFIER` feature) is out of scope.
- **Network sandbox enforcement of unix sockets and proxy ports.**
  permissions-07 adds the config fields and deny-list enforcement; binding to an
  HTTP/SOCKS proxy and allowing unix sockets in the shell sandbox backend is a
  sandbox-backend feature deferred to a sandbox-runtime phase. The config knobs
  are validated placeholders, not active enforcement - documented as such so no
  one mistakes them for live controls.
- **Windows-specific path canonicalization (8.3 short-name normalization via
  GetLongPathNameW).** Per the reference's own rationale (filesystem.ts:513-532)
  zcode uses pattern DETECTION, not normalization. We detect `~\d`, long-path
  prefixes, ADS colons, etc. and require approval rather than trying to canonical-
  ize them.
- **subcommandResults / permissionPromptTool / asyncAgent reason types.** Omitted
  from the permissions-14 taxonomy because they depend on Bash subcommand
  splitting and external permission-prompt tooling not present in this phase.
