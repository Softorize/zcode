# Project Wiki Index

Auto-maintained table of contents for this project's knowledge base. Updated on every ingest.

## Architecture

- [[architecture]] - high-level shape of the system (stub, expand as it stabilizes)

## Decisions

- [[cc-parity-deep-modules]] - PRD #534 parity phases, the deep modules added, and why the gap inventory must be verified before building (it over-reported gaps 6+ times)
- [[cc-parity-audit-2026-05]] - full 2026-05-29 audit: 453 confirmed gaps, 30-phase plan in docs/parity-audit-2026-05-29/; SDK/headless control protocol is the biggest zero-coverage gap; completeness critic caught dimension-selection blind spots
- [[mcp-scoped-config-live-wiring]] - Phase 6: how the structured scoped MCP config + dynamic headers reach the LIVE client (lazy cached ServerConfig merge + transient http_extra_headers) without a Server->ServerConfig type rewrite; what is wired vs deferred
- [[sdk-headless-live-wiring]] - Phase 21: how `--print`/`--output-format json|stream-json` and `--input-format stream-json` reach the SDK serializers + can_use_tool control relay via src/sdk/headless.zig + main.zig runHeadlessDispatch (sdk_relay reuse, synchronous block-read relay, live-control subtypes); the tiered-auto/git-filter/StreamTooLong test gotchas; what is wired vs deferred
- [[hash-memory-capture-mode]] - Phase 15 Task 3 (ui-render-03): `#`-prefix prompt appends to project ZCODE.md/CLAUDE.md under `## User Memories` (read-modify-atomic-write, 0o644); randomized confirmation from rng byte; cwd().rename not renameAbsolute for relative project paths
- [[styled-compact-boundary]] - Phase 15 Task 5 (ui-render-05): `✻ Conversation compacted (ctrl+o for history)` rendered via pure `compaction.renderCompactBoundary`; structured marker stays the stored form; `/compact` surfaces it color-agnostic (transcript strips SGR / markdown render path is not raw-SGR-safe)
- [[syntax-highlight-diff-gate]] - Phase 15 Task 6 (ui-render-07): `CLAUDE_CODE_SYNTAX_HIGHLIGHT` gates diff-content highlighting; zcode defaults ON (reference defaults OFF) so a falsy value is the only off-switch; flag read once and threaded as `syntax_on` to `writeDiffCodeLine`; word-diff pair path still skips highlighting
- [[fuzzy-picker-preview-thresholds]] - Phase 24 Task 24.8 (ui-dialogs-09): pure `previewOnRight(kind, cols)` helper keys the side-vs-bottom preview by picker (QuickOpen 120 / GlobalSearch 140 / History 100; only GlobalSearch 120->140 was a real delta); QuickOpen+GlobalSearch file previews syntax-highlighted via `langFromPath` (exact extension table, NOT prefix-based parseCodeLang) + `writeCodeLine` (colour gated on isatty, so manual-only); History stays single-column (no file preview to place) -- documented deviation

## Gotchas and footguns

- [[ci-and-build]] - which CI checks to trust, fmt-check before push, 0.16 linux SIG footgun, ubuntu hang #527
- [[test-discovery]] - `zig build test` skips unregistered modules' tests; register in src/main.zig comptime block
- [[inferred-error-set-cycles]] - `dependency loop` build errors in agent_runtime; fix with one explicit `anyerror`
- [[anthropic-prompt-caching]] - cache the static system prefix (split at the boundary); request order system->tools->messages; dynamic content busts the cached prefix
- [[native-mode-steering-heuristics]] - PRD #533 dropped all nudges in native mode; action-narration (0.11.70) and question-narration (0.11.72) stalls still need targeted re-adds. Recipe for adding new stall patterns.
- [[repl-runtime-permission-mode-wire]] - live permission mode crosses REPL->runtime via the opaque Handler.command channel (`__set_permission_mode`); plan entry strips dangerous Bash allow rules; no mid-overlay re-decide (runtime is blocked inside handler.call)
- [[lifecycle-hook-emission-wiring]] - hook ENGINE (runEvent) vs EMISSION call sites are two separate layers; lifecycle hooks fire from agent_runtime.zig (SessionStart lazy on first turn, UserPromptSubmit blocks pre-prompt, Stop force-continues via labeled stop_retry loop, SessionEnd in deinit). is_test seam: `hooks_test_override`
- [[per-tool-result-size-threshold]] - tools-10: ToolSchema.max_result_size_chars (0=global default, maxInt=never artifact for Read, 20k for Grep); maxResultSizeForTool lookup must stay alias-aware (read->Read, grep->Grep) because builtin_schemas only carries overrides on some alias spellings; value type so no dup/free
- [[memory-fork-pattern]] - Phase 10 memory forks (extract_memories, session_memory): tool restriction is enforced at executeToolCall dispatch via ToolExecContext flags (auto_mem_dir / session_mem_file), NOT schema filtering; recursion guard depth==0 && interactive; zcode has no auto-compact toggle; token metric must match autocompact; `.session_memory` is two unrelated things; O_EXCL-then-template file creation
- [[session-jsonl-rewrite-and-consistency]] - sessions-08: removeTurnByUuid decodes/filters/re-encodes the JSONL (encrypted in -> encrypted out, corrupt lines verbatim, atomic temp+rename); checkResumeConsistency is count-based (SessionSnapshot.message_count_at_snapshot, 0=skip), not a parent-UUID DAG; store primitives shipped but NOT yet wired into rewind (sessions-01 has no disk-write path yet); test cannot switch on Store.init's inferred error names -> catch-all + SkipZigTest for keychain-dependent tests
- [[plugin-scope-collision-in-tests]] - plugins-01: `plugins.list` walks BOTH the user root (`<HOME>/.zcode/plugins`) and the workspace root (`<cwd>/.zcode/plugins`); a test that pins HOME == cwd double-counts every plugin and collides the two `plugin_settings.json` files. Keep HOME and cwd as distinct tmp dirs.
- [[env-override-map]] - sdk-headless-13: `core/env.zig` keeps a process-global override map that `getenv` consults before libc; `update_environment_variables` stdin messages set it (auth-token refresh); shadows the real env for all callers, never mutates it; tests MUST `defer env.clearOverrides()`; log key names only, never values.
- [[fallback-swap-already-wired]] - Phase 22 Task 22.3 (agent-loop-deep-03): the overload-fallback swap was already wired end-to-end (agent_history.callWithAdapter counts 3 consecutive 529s -> error.FallbackTriggered -> agent_runtime.callModel applyModelOverride + retry-once), contra the audit's "no caller" claim. The one real gap: persist the swap as a `.system` history turn (`announceSwap` -> "Switched to X due to high demand"). agent_runtime loop builds its adapter internally so no mock-adapter injection at that level; gate is tested in agent_history.zig.
- [[reactive-compaction-already-wired]] - Phase 22 Task 22.5 (agent-loop-deep-14): the 413 -> reduce-history -> retry recovery was already wired end-to-end (agent_history.callWithAdapter intercepts error.RequestTooLarge before the retriable gate, calls reactive_compaction.reduce on a request-scoped history copy, MAX_REACTIVE_RETRIES=2 spiral guard), contra the audit's "never called" claim. Built as Task 7.5. The one real gap: surface the recovery onto TurnResult.compaction_applied via a new `reactive_applied_out: ?*bool` (mirrors fallback_out), folded into compaction_applied_any. Borrow-vs-own: reduce() returns shallow copies that borrow content from the input history; free only the slice.
- [[external-claudemd-includes-refused]] - Phase 24 Task 24.7 (ui-dialogs-13, CONDITIONAL): zcode's resolveImportPath (instructions.zig:1179) refuses every external @include (absolute, any `..`, `~/` outside `.claude`/`.zcode`), so the reference's ClaudeMdExternalIncludesDialog has nothing to gate. Downgraded to a documented deviation: zcode is stricter (refuses) rather than prompting. Shipped only a pin test asserting the four denial cases + relative containment + the `~/.claude` config-dir exception.

## Decisions (ADRs in docs/adr/)

- KAIROS is a dedicated process, not bolted onto remote_daemon (ADR 0007); allowlist autonomy (ADR 0008); REPL coexistence via cron-ownership lock + presence (ADR 0009). Full design: docs/KAIROS.md.

## Domain rules

_No pages yet._

## Runbooks

_No pages yet. Add one per operational procedure under `pages/runbooks/`._

## External APIs

_No pages yet._
