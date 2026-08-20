---
title: Claude Code parity (PRD #534) - deep modules and the inventory lesson
tags: [decision, parity]
created: 2026-05-23
updated: 2026-05-23
sources:
  - docs/CC_PARITY_GAP_INVENTORY.md
  - docs/prd_cc_parity.md (issue #534)
---

# Claude Code parity (PRD #534)

## What was built

Nine phases of functional-equivalence parity with claude-code-main, each a checkpoint
commit (0.11.53 -> 0.11.61) with the suite green. Pure deep modules added in `src/core/`:

- P1 `tool_name_map`, `command_canonical` - reference-exact model/user-facing names.
- P2 `permission_decision` - the five reference modes (default/acceptEdits/plan/
  bypassPermissions/dontAsk). Glob arg matching added to the existing `permission_rules`.
- P3 `hook_event`, `hook_matcher`, `hook_io`, `hook_config` - the 27-event JSON hook
  contract; user settings.json command hooks wired into `hooks.run` (stdin via temp-file
  redirect).
- P4 `backoff`, `fallback_model`, `budget_control`, `reactive_compaction`; provider
  `error.ServerOverloaded` (529/503) added as the fallback trigger seam.
- P5 `mcp_output_limits` (desc 2048 cap + spill threshold), wired into MCP tool sanitize.
- P6 `session_search`, `session_export_md`; `session export <id> md` emits Markdown.
- P7 `tips` + `/tips` command.
- P8 `autocomplete` (slash/@-mention context detection + ranking).
- P9a `cc_stub_commands` - ~20 reference commands recognized (easter eggs answer;
  cloud/external ones return a labeled stub).

## The inventory lesson (important)

The gap inventory in `docs/CC_PARITY_GAP_INVENTORY.md` was produced by parallel
exploration agents and **over-reported missing features on six-plus subsystems**. Things
the inventory listed as gaps that already existed and were wired:

- the allow/deny/ask permission **rule engine** (`core/permission_rules.zig`, cwd-scoped,
  file-persisted)
- **rewind** (`/rewind` + picker + `handleRewindToHistoryIndex`)
- memory **freshness caveat** injection (`memory.renderForPrompt`)
- **auto-compaction** trigger (`compaction.maybeCompact` threshold)
- **effort -> thinking-budget** bands (`anthropic.budgetForEffort`, wired)
- MCP **prompts-as-commands** (`skill_types.mcpPromptToSkill`, PRD #532)
- **plugin manifest** parsing (`core/plugins.zig`)

Takeaway: treat an exploration-agent gap survey as leads, not facts. Before building a
"missing" module, grep for the capability first - several phases collapsed to "already done,
add the one genuinely-missing piece" once verified. This is why the P9 removal step was
deferred for explicit veto: the same survey generated the removal list, and the candidates
are working tested features.

## Deferred / follow-up (integration, external deps, or user-gated)

- Loop-level model-swap-on-overload retry (module + `error.ServerOverloaded` seam exist).
- Project-scope settings.json hooks (trust-gated) and non-tool hook event emission points.
- Plugin marketplace HTTP backend; LSP diagnostics injection.
- The P9 removal commit (strip reference-less extras) - DEFERRED for per-item user veto.

## Related
- [[anthropic-prompt-caching]] - prior prompt-parity work (PRD #533)
- [[test-discovery]] - register every new core module in main.zig or its tests are skipped
