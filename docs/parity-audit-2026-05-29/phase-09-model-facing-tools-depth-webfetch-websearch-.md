# Phase 9: Model-facing tools depth: WebFetch/WebSearch, AskUserQuestion, ToolSearch scoring, StructuredOutput, LSP, per-tool schemas

## Overview

**What.** This phase deepens the model-facing tool surface so each tool behaves
like the reference implementation rather than a thin shim. It covers nine tool
areas grouped into four clusters:

1. **Web tools** (tools-01, tools-02, tools-03, tools-11): give WebFetch a
   `prompt` parameter + secondary-model summarization, cross-host redirect
   detection, per-domain ask-rule suggestions + binary/PDF persistence, and give
   WebSearch `allowed_domains`/`blocked_domains` filters.
2. **Clarification + discovery** (tools-04, tools-05, tools-06): expand
   AskUserQuestion from a single free-text question to the 1-4 structured
   questions-with-options shape; replace ToolSearch's substring match with a
   scored keyword search that understands `+required` terms, CamelCase/MCP name
   splitting, and a new `search_hint` field; add the `search_hint` field to the
   tool schema struct.
3. **Output + config** (tools-07, tools-09, tools-12): add a model-facing
   ConfigTool (get/set settings), add a StructuredOutput tool for non-interactive
   structured JSON output, and add a per-tool `output_schema` declaration.
4. **Code intelligence + persistence** (tools-08, tools-10, analytics-09): add
   the four missing LSP operations (workspaceSymbol + call-hierarchy), an LSP
   diagnostic baseline tracker, and per-tool `max_result_size_chars` overrides so
   Read is never artifacted while Grep/etc. cap tighter.

**Why.** These are the gaps where zcode's tool I/O surface is shallower than the
reference, costing the model accuracy (WebFetch returns raw stripped HTML instead
of a focused answer), context budget (no per-tool persistence caps, no Read
exemption), and capability (single-question clarification, no scored tool
discovery, no model-driven config, no SDK-grade structured output). None of these
are auth/cloud features; all are local and within scope.

**Dependencies.** Phase 1 (core runtime, `rt.io`, `std_io` facades), Phase 6
(tool dispatch + schema infrastructure), Phase 7 (permission/policy classifier +
preapproved-host integration). The WebFetch prompt pass reuses the same
`agent_history.callModel` path the main agent uses, with a model override to a
small/fast model (the model registry already lists `claude-haiku-4-5`).

**Effort.** XL. Roughly: WebFetch prompt pass (L), redirect detect (M), preapproved
domain rules + PDF persist (M), WebSearch filters (S), AskUserQuestion multi (L),
ToolSearch scoring (M), search_hint field (S), ConfigTool (M), LSP ops (M), LSP
diag baseline (L), StructuredOutput (L), per-tool maxResultSize (M), output_schema
(L).

**Style note.** Many of these gaps were over-reported by the survey. Where our
implementation already covers part of the behavior (preapproved-host auto-allow,
SSRF defense, scheme-redirect protection, `select:` multi-select, `/format json`
schema plumbing), this plan explicitly scopes the work down to the genuine delta
and says so. Do not re-implement what already exists.

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| tools-01 | WebFetch `prompt` param + sub-LLM summarization | medium | L | No `prompt` field; `webFetch(allocator,cwd,url,max_bytes)` strips HTML and returns raw text. No secondary-model call exists. |
| tools-02 | WebFetch cross-host redirect detection | low | M | `curl -L` silently follows; `--proto-redir=http,https` blocks scheme escalation. No host comparison or "REDIRECT DETECTED" message. |
| tools-03 | WebFetch preapproved auto-allow + domain ask-rules + PDF persist | low | M | Preapproved auto-allow PRESENT (policy.zig downgrades to LOW). Missing: `domain:<host>` ask-rule suggestions, binary/PDF persistence. |
| tools-04 | AskUserQuestion 1-4 questions, headers, rich options, multiSelect, preview | medium | L | Single `{question, choices}` schema; `parseChoiceList` extracts only labels. No multi-question, headers, descriptions, previews, per-question answers. |
| tools-05 | ToolSearch scored keyword search + `+required` + `search_hint` | medium | M | `select:` CSV works; keyword path is plain `containsIgnoreCase`. No scoring, no `+required` (advertised in schema but not implemented), no CamelCase split. |
| tools-06 | `search_hint` field on tool schemas | low | S | `usage_hint` exists for general guidance; no `search_hint`, no search-hint-aware ranking. |
| tools-07 | model-facing ConfigTool (get/set) | low | M | `/config` REPL command only; not in dispatch table or `builtin_schemas`. |
| tools-08 | LSP 9 operations (currently 5) | low | M | `documentSymbol, goToDefinition, findReferences, hover, goToImplementation`. Missing `workspaceSymbol, prepareCallHierarchy, incomingCalls, outgoingCalls`. |
| tools-09 | StructuredOutput tool for non-interactive structured JSON | medium | L | `response_schema` plumbing + `/format json` + `--json` exist. No StructuredOutput tool, no non-interactive auto-add, no client-side validation. |
| tools-10 | per-tool `max_result_size_chars` (vs one global threshold) | low | M | Single `cfg.tool_output_artifact_threshold_bytes` for all tools. No per-tool override; Read can be artifacted. |
| tools-11 | WebSearch `allowed_domains`/`blocked_domains` | low | S | `{query, max_bytes}` only. No domain filter params or logic. |
| tools-12 | per-tool `output_schema` (structured content / mcpMeta passthrough) | low | L | `ToolSchema` has no `output_schema`; handlers return plain `[]u8`; no structured-result envelope. |
| analytics-09 | LSP diagnostic baseline tracking (new errors) | medium | L | No diagnostic ops; no `publishDiagnostics` handling or baseline comparison. |

---

## Implementation tasks

### Task 1 (tools-01): WebFetch `prompt` parameter + secondary-model summarization

**Goal.** Add a `prompt` field to WebFetch; after fetching+stripping, run a
small/fast-model pass that answers the caller's prompt over the content, and
return that focused answer instead of raw markdown.

**Reference behavior + file:line.** `WebFetchTool.ts:24-29` (inputSchema
`url`+`prompt`), `:264-278` (preapproved+markdown+under-MAX bypass vs
`applyPromptToMarkdown`), `utils.ts:484-530` (`applyPromptToMarkdown` ->
`queryHaiku`), `MAX_MARKDOWN_LENGTH = 100_000` (`utils.ts:128`). The
reference only passes content through raw when it is a preapproved host
returning `text/markdown` under MAX length; everything else goes through the
Haiku pass.

**Target Zig files.**
- `src/tools/web.zig` (edit): change `webFetch` signature to thread an optional
  `prompt`, add `applyPromptToContent`.
- `src/tools/web_summarize.zig` (create): the secondary-model pass. Register in
  `src/main.zig` comptime block.
- `src/tools/tool_schemas.zig` (edit): add `prompt` to the WebFetch
  `json_schema`.
- `src/tools/tool_dispatch.zig` (edit): `handleWebFetch` extracts `prompt` and
  threads it.
- `src/core/web_preapproved.zig` (read; reuse `isPreapprovedUrl`).

**Approach.**
1. Schema: add `"prompt":{"type":"string","description":"What to extract/answer from the fetched page. The page is summarized to answer this prompt before returning."}` to the WebFetch `json_schema`. Keep `prompt` optional (not in `required`) so existing callers that pass only `url` still work; when absent, fall back to current raw-return behavior (this is a deliberate deviation from the reference where `prompt` is required, to avoid breaking the many existing zcode call sites and tests).
2. `web.zig`: change to `pub fn webFetch(allocator, cwd, url, max_bytes, prompt: ?[]const u8)`. After the existing fetch + `html_to_text` step produces `content`:
   - If `prompt == null` -> return `content` unchanged (current behavior).
   - Else if `web_preapproved.isPreapprovedUrl(url)` and content looks like markdown/plain text and `content.len < MAX_MARKDOWN_LENGTH` (define `const MAX_MARKDOWN_LENGTH = 100_000`) -> return `content` raw (mirrors the reference bypass).
   - Else -> `web_summarize.applyPromptToContent(allocator, prompt.?, content, ...)`.
3. `web_summarize.zig`: build a single-shot `types.ModelRequest` whose user prompt is the reference shape (port `makeSecondaryModelPrompt`: "Web page content:\n<content truncated to MAX>\n\n<prompt>"). Truncate content to `MAX_MARKDOWN_LENGTH` with a `\n\n[Content truncated due to length...]` marker. Call the model through the existing `agent_history.callModel(allocator, cfg, provider, model, interactive=false, reporter=null, request)` path with a small-model override. Resolve the small model from config (add `cfg.small_fast_model`, default `"claude-haiku-4-5"`; if the active provider is not Anthropic, fall back to the active model rather than failing). Return `response.text`. On any model error, log and gracefully fall back to returning the raw stripped content prefixed with a one-line note (`[web_fetch: summarization unavailable, returning raw content]`) so the tool never hard-fails.
4. Thread `cfg`/provider/model into `web.zig`. Since `web.zig` is allocator+cwd only today, pass a small `FetchContext` struct (cfg pointer, provider, model) from `handleWebFetch`. `handleWebFetch` already has access to the runtime config via `ToolExecutionRequest`; confirm `req` carries enough (if not, add the needed fields to `ToolExecutionRequest` in `tool_dispatch.zig`).
5. `handleWebFetch`: extract `prompt` via `getArg(req.args, "prompt")` and thread it.

**Acceptance criteria.**
- Write a test in `web_summarize.zig` that builds the secondary prompt from a fixed content+prompt and asserts the content is truncated at `MAX_MARKDOWN_LENGTH` with the truncation marker.
- Write a test asserting that when `prompt == null`, `webFetch`'s post-processing returns the stripped content unchanged (use a loopback/mock or factor the post-fetch decision into a pure helper `decideWebFetchResult(prompt, url, content)` that is unit-testable without a network call).
- Write a test asserting a preapproved markdown URL under MAX bypasses summarization (returns raw).
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Factor the network-free decision logic (truncation, bypass
decision, prompt assembly) into pure functions and unit-test those under
`tools/test_runner.zig`. Do not make a live model call in tests; the model call
itself is covered by manual verification.

**Risk / footguns.** `std.process.run` cap gotcha already handled in `web.zig`
(StreamTooLong -> ranged refetch). The model call must not block forever; reuse
the same timeout/cancel plumbing the main loop uses (`http_common.isCancelRequested`).
Do not introduce a second HTTP client; route the model call through the existing
provider adapter. Avoid an import cycle: `web_summarize.zig` importing
`agent_history.zig` may pull in heavy deps -- if a cycle appears, pass a
`callModelFn` function pointer down from the dispatch layer instead of importing
`agent_history` directly (the runtime already exposes `callModelTrampoline`).

**Size.** L.

---

### Task 2 (tools-02): WebFetch cross-host redirect detection

**Goal.** When a fetch redirects to a different host, do not silently follow;
return a "REDIRECT DETECTED" message naming both URLs and asking the model to
re-call WebFetch with the redirect URL.

**Reference behavior + file:line.** `WebFetchTool.ts:216-249` (redirect branch +
message), `utils.ts:205-243` (`isPermittedRedirect`: same host modulo `www.`,
same protocol+port, no creds), `utils.ts:262-329` (`maxRedirects:0` + manual
follow). The reference permits same-host redirects (and `www.` add/remove) and
only surfaces a message on a genuine cross-host hop.

**Target Zig files.**
- `src/tools/web.zig` (edit): capture the final effective URL from curl and
  compare hosts.
- `src/core/url_host.zig` (create or reuse): a host-extraction +
  same-host-modulo-www comparison helper. If `egress.zig` already extracts host,
  reuse it; otherwise create a small pure helper and register in `main.zig`.

**Approach.**
1. Add `%{url_effective}` to the curl `--write-out` marker alongside the existing
   `%{http_code}` so we capture the final URL after redirects. Extend
   `parseCurlResponseWithStatus` to also parse the effective URL.
2. Add `fn sameHostModuloWww(a, b: []const u8) bool` (port `isPermittedRedirect`'s
   hostname rule: strip a leading `www.`, compare case-insensitively; also require
   same scheme). Extract host from the original `url` and from `url_effective`.
3. If hosts differ, return a `REDIRECT DETECTED:` message in the reference's
   format (original URL, redirect URL, status, and the re-call instruction
   including the original `prompt`). Do this BEFORE the html_to_text / summarize
   step.
4. Keep `curl -L` (we still want same-host redirect following). The detection is
   post-hoc on the effective URL, which is simpler than the reference's manual
   `maxRedirects:0` loop and is sufficient for the "surface a host change" goal.
   Note this deviation in a code comment.

**Acceptance criteria.**
- Unit test `sameHostModuloWww`: `example.com`==`www.example.com`,
  `a.com`!=`b.com`, scheme mismatch is not same-host.
- Unit test that given a parsed curl response where `url_effective` host differs
  from the requested host, the result string starts with `REDIRECT DETECTED:` and
  contains both URLs.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Pure-function tests for host comparison and for the
result-shaping branch (feed a synthesized `CurlResponseWithStatus`-like struct;
no network). Run under `tools/test_runner.zig`.

**Risk / footguns.** `%{url_effective}` is URL-shaped and may contain the marker
delimiter characters; choose a marker unlikely to collide and parse from the
last occurrence (the existing code already uses `lastIndexOf`). Relative
redirects are resolved by curl already, so `url_effective` is absolute.

**Size.** M.

---

### Task 3 (tools-03): WebFetch domain ask-rule suggestions + binary/PDF persistence

**Goal.** Two narrow deltas (preapproved auto-allow already exists): (a) when a
non-preapproved WebFetch host needs approval, suggest a `domain:<host>` ask/allow
rule; (b) when the response is binary (PDF etc.), persist it to disk and append a
note with the path.

**Reference behavior + file:line.** `WebFetchTool.ts:50-64`
(`webFetchToolInputToPermissionRuleContent` -> `domain:<hostname>`), `:104-180`
(preapproved bypass + `domain:` rule suggestions), `:280-285` (persistedPath note),
`utils.ts:442-449` (`isBinaryContentType` + `persistBinaryContent`).

**Target Zig files.**
- `src/policy/policy.zig` (edit): where WebFetch needs approval, attach a
  suggested rule string `domain:<host>` to the decision (if the policy decision
  struct carries suggestions; if not, this is a permission-subsystem addition --
  scope to producing the suggestion string and wiring it where rule suggestions
  are surfaced).
- `src/tools/web.zig` (edit): detect binary content-type and persist.
- `src/core/web_artifacts.zig` (create): `persistBinaryContent` equivalent --
  write bytes to a session-scoped artifacts dir with a mime-derived extension.
  Register in `main.zig`. Reuse `tool_artifacts.zig` patterns if they already
  write session artifacts.

**Approach.**
1. Binary detection: the current curl pipeline does not return Content-Type
   (the comment in `web.zig:9-13` notes this). Add `%{content_type}` to the
   `--write-out` marker so we capture it. Add `fn isBinaryContentType(ct)` (true
   for `application/pdf`, `application/octet-stream`, `image/*`, `audio/*`,
   `video/*`, `application/zip`, etc.).
2. When binary: write the raw bytes (pre-strip) to
   `web_artifacts.persistBinaryContent(allocator, session_id, bytes, content_type)`
   which returns `{path, size}`. Derive the extension from the mime type
   (`application/pdf` -> `.pdf`, etc.). Append `\n\n[Binary content (<ct>, <size>) also saved to <path>]` to the returned result (mirrors reference). For PDFs the reference still runs the text path; we can append the note to whatever text we already produce.
3. Domain rule suggestion: add `fn webFetchRuleContent(allocator, url) -> "domain:<host>"`. In `policy.zig`, when WebFetch is not preapproved and resolves to `ask`, surface this suggestion through whatever channel the permission UI already uses for suggested rules. If there is no existing suggestion plumbing, scope this sub-task to: (a) implement `webFetchRuleContent`, (b) include the suggested rule text in the ask prompt message ("approve once, or add allow rule `domain:<host>`"). Note in the plan that full rule-persistence wiring belongs to the permission subsystem and may be deferred if absent.

**Acceptance criteria.**
- Unit test `webFetchRuleContent("https://docs.foo.com/x")` == `"domain:docs.foo.com"`.
- Unit test `isBinaryContentType`: pdf/octet-stream true, `text/html` false.
- Unit test that the persisted-note string is appended in the documented format
  given a synthesized `{path,size,content_type}`.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Pure-function tests for `webFetchRuleContent` and
`isBinaryContentType`. For persistence, use `core/test_helpers.tmpDirPath` to get
a real absolute dir (do NOT pass `"."` per CLAUDE.md) and assert the file exists
with the right extension and bytes.

**Risk / footguns.** Capturing Content-Type via `--write-out %{content_type}`
adds another field to the marker; update `parseCurlResponseWithStatus` carefully
(it now parses 3 trailing fields). Use `tmpDirPath`, not relative cwd, in the
persistence test. Do not persist into the repo working tree -- use the session
artifacts dir.

**Size.** M.

---

### Task 4 (tools-11): WebSearch `allowed_domains` / `blocked_domains` filters

**Goal.** Add optional `allowed_domains` and `blocked_domains` array params to
WebSearch and filter results by domain.

**Reference behavior + file:line.** `WebSearchTool.ts:25-37` (schema),
`:76-84` (`makeToolSchema` passes the arrays to the server-side web_search tool).
The reference delegates filtering to the Anthropic server tool; ours is
client-side over DuckDuckGo instant-answer JSON, so we filter the parsed results
ourselves.

**Target Zig files.**
- `src/tools/tool_schemas.zig` (edit): add `allowed_domains` and `blocked_domains`
  to the WebSearch `json_schema` (arrays of strings).
- `src/tools/web.zig` (edit): `webSearch` signature gains the two optional
  domain lists; filter `RelatedTopics`/abstract URLs by domain in
  `summarizeInstantAnswer`.
- `src/tools/tool_dispatch.zig` (edit): `handleWebSearch` parses the arrays
  (JSON or comma-delimited) and threads them.

**Approach.**
1. Schema: add `"allowed_domains":{"type":"array","items":{"type":"string"},"description":"Only include results whose URL host matches one of these domains."}` and the `blocked_domains` analogue.
2. `handleWebSearch`: parse each arg. Accept either a JSON array string or a
   comma-delimited string (reuse `parseChoiceList`-style tolerance) -> `[][]const u8`.
3. `webSearch` / `summarizeInstantAnswer`: when emitting a `RelatedTopics` line
   with a `FirstURL` (or the abstract `Source:`), extract the host and apply:
   blocked wins (drop if host matches any blocked domain), then if `allowed_domains`
   is non-empty, keep only hosts matching an allowed domain. Host match = exact or
   suffix (`foo.com` matches `docs.foo.com`).
4. If filtering removes all results, fall back to the existing `searchGuidance`
   message.

**Acceptance criteria.**
- Unit test: `summarizeInstantAnswer` with a fixed JSON containing two
  RelatedTopics (one on `wikipedia.org`, one on `example.com`) and
  `blocked_domains=["example.com"]` returns only the wikipedia one.
- Unit test: `allowed_domains=["wikipedia.org"]` keeps only the wikipedia one.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Extend the existing `summarizeInstantAnswer` tests in
`web.zig` with domain-filter variants (network-free). Run under
`tools/test_runner.zig`.

**Risk / footguns.** Host extraction must handle `https://` prefix and trailing
path. Keep suffix-match anchored on a `.` boundary so `evil-example.com` does not
match `example.com`.

**Size.** S.

---

### Task 5 (tools-04): AskUserQuestion multi-question with headers, rich options, multiSelect

**Goal.** Expand AskUserQuestion to accept 1-4 questions, each with a `header`
chip (<= 12 chars), 2-4 rich options (`label`, `description`, optional `preview`),
and a `multiSelect` flag; return per-question structured answers.

**Reference behavior + file:line.** `AskUserQuestionTool.tsx:14-67` (option schema
with `preview`; question schema with `header`/`options.min(2).max(4)`/`multiSelect`;
inputSchema `questions.min(1).max(4)`), `:69-74` (output: per-question answers,
question text -> answer string, multi-select comma-joined), `prompt.ts:10-44`
(preview guidance + recommended-option convention).

**Target Zig files.**
- `src/tools/tool_schemas.zig` (edit): replace the AskUserQuestion `json_schema`
  with the questions-array shape.
- `src/agent_tools.zig` (edit): `handleAskUserQuestionTool`, `AskUserResult`,
  `parseChoiceList`/`extractChoiceLabel`. Add a `Question` struct and a parser
  that handles both the new array form and the legacy `{question, choices}` form
  (back-compat).
- `src/tools/ask_question.zig` (create, optional): if the parsing/rendering logic
  grows, factor it into a deep module and register in `main.zig`. Otherwise keep
  in `agent_tools.zig`.
- The interactive selection UI (whatever renders the choice prompt today) (edit):
  render header chips, per-option descriptions, and side-by-side preview when an
  option carries one; support multi-select toggling when `multiSelect` is true.

**Approach.**
1. New schema:
   `{"type":"object","properties":{"questions":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"question":{"type":"string"},"header":{"type":"string","description":"<= 12-char chip label"},"multiSelect":{"type":"boolean"},"options":{"type":"array","minItems":2,"maxItems":4,"items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"},"preview":{"type":"string"}},"required":["label"]}}},"required":["question","options"]}}},"required":["questions"]}`.
2. Parser: introduce `const Question = struct { question, header, multi_select: bool, options: []Option }` and `const Option = struct { label, description, preview: ?[]const u8 }`. Parse the `questions` array; if the payload is the legacy `{question, choices}` shape, wrap it into a single `Question` with `options` synthesized from the existing `parseChoiceList` (preserve back-compat -- the existing tests at `agent_tools.zig:3018-3094` must still pass).
3. `AskUserResult`: change `answer` from a single `[]const u8` to a slice of
   per-question answers (`[]Answer{ question: []const u8, value: []const u8 }`).
   For `multiSelect`, join selected labels with `, ` (matches reference output
   semantics). Keep a convenience accessor that returns the first answer for any
   call sites that still expect one string (audit `handleAskUserQuestion` callers).
4. Truncate/validate `header` to 12 chars; clamp options to 2-4 (reject <2 with a
   clear tool-error string; cap >4). Always offer an implicit "Other" (free text)
   as the reference does -- the UI already supports custom input; ensure it stays.
5. UI: render each question with its header chip and options; show option
   `description` under each label; when any option in a question has a `preview`,
   render the preview alongside (or below) the focused option. Honor `multiSelect`
   by allowing multiple toggles before confirm.

**Acceptance criteria.**
- Write a test that parses a 2-question payload (each with 2-3 rich options,
  one with `multiSelect:true`) and asserts the parsed `Question`/`Option`
  structs carry `header`, `description`, and `preview` correctly.
- Write a test that the legacy `{question, choices:"[\"a\",\"b\"]"}` payload still
  parses into a single question with two options (back-compat).
- Write a test that a multiSelect answer of two labels serializes to `"a, b"`.
- Existing `parseChoiceList` tests still pass.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Unit-test the parser and answer serialization in
`agent_tools.zig` (or `ask_question.zig`) under `tools/test_runner.zig`. The
interactive UI path is verified manually (see Verification).

**Risk / footguns.** `ObjectMap.put`-after-parse pointer gotcha (CLAUDE.md): when
walking the parsed `questions` array, take object pointers carefully; do not hold
a `*ObjectMap` across a realloc. Free the per-question/option owned strings in a
`deinit` that mirrors the parse allocations (the survey notes `AskUserResult` owns
its answer). Keep the implicit "Other" option so the model can never trap the
user with a closed set.

**Size.** L.

---

### Task 6 (tools-06): `search_hint` field on `ToolSchema`

**Goal.** Add a `search_hint` field to the `ToolSchema` struct and populate it on
the deferred tools that benefit most, so ToolSearch scoring (Task 7) can weight it.

**Reference behavior + file:line.** `Tool.ts:373-378` (searchHint doc -- "curated
3-10-word capability phrase scored above the description"); used in
`ToolSearchTool.ts:243,264,283-285`; example `ConfigTool.ts:69`
(`searchHint: 'get or set Claude Code settings (theme, model)'`).

**Target Zig files.**
- `src/core/types.zig` (edit): add `search_hint: []const u8 = ""` to `ToolSchema`
  (after `usage_hint`, line ~112).
- `src/tools/tool_schemas.zig` (edit): set `search_hint` on high-value tools
  (WebFetch: "fetch and extract content from a URL"; WebSearch: "search the web";
  AskUserQuestion: "prompt the user with a multiple-choice question"; ToolSearch;
  Task family; LSP: "code navigation: definitions, references, hover"; etc.).
- `src/tools/tool_schemas.zig` `collectSchemas`/`freeSchemas` (edit): dup/free the
  new field for dynamic (chrome/MCP) schemas if they ever set it.

**Approach.**
1. Add the field with a `= ""` default (zero-impact on all existing literals).
2. Add `search_hint` to the dup/free paths in `collectSchemas` and `freeSchemas`
   (currently they dup name/description/json_schema/usage_hint). Mirror the
   `usage_hint` handling exactly (free only when `len > 0`).
3. Populate hints on ~8-12 of the deferred tools. Keep them 3-10 words.

**Acceptance criteria.**
- Write a test asserting a known schema (e.g. WebFetch) has a non-empty
  `search_hint`.
- Write a test asserting `collectSchemas` round-trips `search_hint` without leak
  (run under the leak-checking test allocator).
- `zig build -Doptimize=ReleaseFast` passes (proves all `ToolSchema` literals
  still compile with the new defaulted field).

**Test strategy.** Unit tests in `tool_schemas.zig` under `tools/test_runner.zig`.

**Risk / footguns.** This is only useful once Task 7 reads it; ship them together.
The dup/free symmetry is the one place a leak or double-free can creep in -- match
`usage_hint` exactly.

**Size.** S.

---

### Task 7 (tools-05): ToolSearch scored keyword search with `+required` terms and CamelCase/MCP splitting

**Goal.** Replace the substring keyword path with a scored search: parse tool
names into parts (CamelCase + MCP `__`/`_` splitting), support `+required` terms
(pre-filter to tools matching all required terms), score name-part (10/12) /
partial (5/6) / search_hint (4) / description (2), sort by score, return top
`max_results`. Report pending MCP servers when no match. Keep `select:` CSV as-is.

**Reference behavior + file:line.** `ToolSearchTool.ts:132-161` (`parseToolName`),
`:186-302` (required-term partition + pre-filter + scoring), `:328-433`
(`select:` multi + pending servers), `:444-470` (output). Scoring weights:
name-part exact `parsed.isMcp ? 12 : 10`, partial `6 : 5`, full-name fallback
`+3` only if score==0, search_hint `+4`, description `+2`.

**Target Zig files.**
- `src/tools/tool_dispatch.zig` (edit): `handleToolSearch` keyword branch.
- `src/tools/tool_search_score.zig` (create): pure scoring helpers
  (`parseToolName`, `scoreTool`, required/optional partition). Register in
  `main.zig`. Keeping the scoring pure makes it directly testable.

**Approach.**
1. `parseToolName(name) -> { parts: [][]const u8, full: []const u8, is_mcp: bool }`:
   if `name` starts with `mcp__`, strip prefix, split on `__` then `_`, lowercase;
   else split CamelCase boundaries (`aB` -> `a b`) and `_`, lowercase. Allocate
   parts in an arena passed by the caller.
2. Query parse: lowercase+trim. Keep the existing exact-name fast path and the
   `mcp__` prefix fast path (port from reference `:199-216`). Split remaining
   query on whitespace; partition into `required` (leading `+`, slice off the `+`)
   and `optional`. `all_scoring_terms = required ++ optional` (or all terms if no
   required).
3. Pre-filter: if any required terms, keep only tools where every required term
   matches a name part (exact or partial), the description (word-ish boundary), or
   the `search_hint`.
4. Score each candidate over `all_scoring_terms` with the reference weights. Drop
   score==0, sort descending, take `max_results`.
5. Output: keep emitting the `<functions>` JSON blocks (our established format --
   the reference emits `tool_reference` blocks which is a 1P-API-specific feature
   we do not target; note this deviation). On zero matches, append a
   `pending_mcp_servers` note IF the MCP client reports connecting servers
   (`mcp_client` exposes pending state; if not readily available, emit the generic
   "no tools matched" message and leave a TODO -- scope pending-server reporting as
   optional).
6. Delete the advertised-but-unimplemented `+required` claim mismatch: the schema
   description at `tool_schemas.zig:362` already advertises `+slack send`; this
   task makes it real.

**Acceptance criteria.**
- Write a test: `parseToolName("WebFetch")` -> parts `["web","fetch"]`, is_mcp
  false; `parseToolName("mcp__slack__send_message")` -> parts
  `["slack","send","message"]`, is_mcp true.
- Write a test: query `"fetch web"` ranks WebFetch above a tool that only mentions
  "web" in its description.
- Write a test: query `"+slack send"` excludes non-slack tools entirely and ranks
  remaining by `send`.
- Write a test: `search_hint` match contributes more than a description-only match
  (depends on Task 6).
- `select:Read,Edit` still returns both.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Unit-test `tool_search_score.zig` pure functions against the
real `builtin_schemas` table under `tools/test_runner.zig`. The `select:` path
already has behavior; add a regression test that it is unchanged.

**Risk / footguns.** Word-boundary matching: the reference uses `\b<term>\b`
regexes for description/hint matches to avoid false positives. Zig has no regex
in std; implement a small boundary check (`term` preceded/followed by non-alnum or
string edge) rather than naive `indexOf`. Use an arena for the per-search parts so
you do not leak. The CamelCase splitter must handle acronym runs (`LSP`,
`HttpRequest`) gracefully -- lowercase first, then a simple lower-to-upper
boundary split is adequate.

**Size.** M.

---

### Task 8 (tools-07): model-facing ConfigTool (get/set settings)

**Goal.** Add a deferred `Config` tool that lets the model read settings (when
`value` omitted, read-only auto-allow) or write them (ask permission on writes),
validating against a small allowlist of supported settings.

**Reference behavior + file:line.** `ConfigTool.ts:36-47` (input
`{setting, value?}`), `:90-92` (`isReadOnly` when value omitted), `:98-107`
(checkPermissions: allow on read, ask on write), `:111-...` (validate supported +
options/booleans, write to global/user settings), `supportedSettings.ts`. The
reference gates the tool to `USER_TYPE==='ant'`; we expose it unconditionally as a
deferred tool (note the deviation).

**Target Zig files.**
- `src/tools/config_tool.zig` (create): handler `handleConfigTool`. Register in
  `main.zig` comptime block.
- `src/tools/tool_schemas.zig` (edit): add the `Config` schema (deferred:
  `should_defer = true`, `search_hint = "get or set zcode settings (theme, model)"`).
- `src/tools/tool_dispatch.zig` (edit): add dispatch entry
  `.{ .names = &.{ "Config", "config" }, .handler = handleConfigTool }`.
- `src/core/config.zig` / `src/repl_commands.zig` (read; reuse the existing
  `/config` read path and the settings keys it already knows).

**Approach.**
1. Schema: `{"type":"object","properties":{"setting":{"type":"string","description":"Setting key, e.g. theme, model, permissions.defaultMode"},"value":{"description":"New value. Omit to read current value."}},"required":["setting"]}`.
2. Define a small supported-settings table (key -> {kind: enum|bool|string, options}). Start with the safe-to-mutate runtime settings the `/config` command already surfaces (theme, model, effort, mode/permissions default, format) -- do not expose secrets/api keys.
3. Read path (`value` omitted): look up the current value and return
   `setting=<k> value=<v>`. This is read-only.
4. Write path: validate the key is supported and the value is valid for its kind
   (enum -> must be one of options; bool -> true/false; string -> as-is). Apply
   the write through the same code path `/config`/`/model`/`/mode` use (mutate the
   runtime config; if a setting is persisted to disk, write via the existing
   settings writer). Return `previous=<old> new=<v>`. Permission: this tool is a
   write when `value` is present -- mark the dispatch/policy so writes route
   through the normal approval path (HIGH/ask), reads stay LOW.
5. Risk classification: in `policy.zig`, treat `Config` with `value` present as a
   mutating tool (ask), `Config` read as read-only (auto-allow). Mirror how other
   read/write tools are classified.

**Acceptance criteria.**
- Write a test that a read (`{"setting":"theme"}`) returns the current theme and
  is classified read-only.
- Write a test that a write to an enum setting with an invalid option returns a
  clear error and does NOT mutate config.
- Write a test that a valid write updates the in-memory config and reports
  previous+new.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Unit tests in `config_tool.zig` against a constructed
`Config`/runtime fixture under `tools/test_runner.zig`. Reuse `rt.installForTest`.

**Risk / footguns.** Do not expose API keys or any secret-bearing setting. Mutating
runtime config from a tool handler must go through the same `@constCast` discipline
the `/config` REPL path uses (`repl_commands.zig:753`); keep the mutation surface
tiny and explicit. Confirm the dispatch handler has access to the runtime config
pointer (the WebFetch summarization task already needs this plumbing -- share it).

**Size.** M.

---

### Task 9 (tools-08): LSP -- add workspaceSymbol + call-hierarchy operations

**Goal.** Add the four missing LSP operations: `workspaceSymbol`,
`prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`.

**Reference behavior + file:line.** `LSPTool/schemas.ts:85-191` (the 9-operation
discriminated union), `:201-215` (`isValidLSPOperation` lists all 9).
`workspaceSymbol` uses `workspace/symbol` with a query; call-hierarchy uses
`textDocument/prepareCallHierarchy` then `callHierarchy/incomingCalls` /
`callHierarchy/outgoingCalls` on the returned item.

**Target Zig files.**
- `src/tools/lsp.zig` (edit): add the four operations to `handleLsp` dispatch and
  the supported-operations error message; add request builders.
- `src/tools/tool_schemas.zig` (edit): update the LSP description + the
  `operation` enum doc to list all 9.

**Approach.**
1. `workspaceSymbol`: needs a `query` arg (not a position). Add
   `getArg(req.args, "query")`. Send `workspace/symbol` with `{"query":<q>}`.
   Reuse `runPositionRequest`'s spawn/read/extract scaffolding by adding a
   `runWorkspaceSymbol` that builds the right body (no `textDocument`).
2. Call hierarchy is two-step:
   `prepareCallHierarchy` -> returns a CallHierarchyItem; then `incomingCalls` /
   `outgoingCalls` take that item. For a single tool call, implement
   `prepareCallHierarchy` to return the prepared item(s) directly. For
   `incomingCalls`/`outgoingCalls`, do prepare-then-call within one handler: send
   `textDocument/prepareCallHierarchy` (id 2), read the item from the response,
   then send `callHierarchy/incomingCalls`/`outgoingCalls` (id 3) with that item.
   The existing single-shot stdin-pipe model writes both messages then reads; for
   the two-step calls you need to read the prepare result before composing the
   second message. Refactor `runPositionRequest` so it can run an extra round:
   keep stdin open, write initialize+prepare, read until the prepare response,
   parse the item, write the call request, read again, close. (Note: the current
   code writes all messages then closes stdin; the call-hierarchy path needs an
   interactive write-read-write-read, so factor a small JSON-RPC client helper.)
3. Update the dispatch chain and the "Supported:" error message in `handleLsp` to
   list all 9.

**Acceptance criteria.**
- `handleLsp` dispatches all 9 operation names (test that an unknown op error
  message lists all 9, and that each known op routes without an "unknown
  operation" error -- can assert on the routing decision without a live server).
- For `workspaceSymbol`, missing `query` returns a clear error.
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Operation-routing is testable without a live LSP server by
asserting the error/branch selection. The full round-trip is verified manually
against `zls` (see Verification). Run unit tests under `tools/test_runner.zig`.

**Risk / footguns.** CLAUDE.md 0.16 gotchas: `readStreaming(io, &.{&buf})` for the
pipe (already used); track offset across reads. The two-step call-hierarchy means
do NOT close stdin after the first write -- the current code sets `child.stdin =
null` after writing; the interactive path must keep it open until both requests
are sent. `child.wait(io)` after the reads is fine (do not call `kill` then
`wait`). Many servers (including zls) have limited call-hierarchy support; degrade
gracefully with a clear "server returned no result" message rather than erroring.

**Size.** M.

---

### Task 10 (analytics-09): LSP diagnostic baseline tracking

**Goal.** Capture a baseline of diagnostics (errors/warnings) for a file/workspace
and report newly-introduced diagnostics on a later check.

**Reference behavior + file:line.** `diagnosticTracking.ts` -- handles
`textDocument/publishDiagnostics` notifications, stores a baseline, and surfaces
"new errors" introduced since baseline.

**Target Zig files.**
- `src/tools/lsp.zig` (edit): add a `diagnostics` operation (or a `getDiagnostics`
  op) that opens the file, waits briefly for `publishDiagnostics`, and returns the
  current diagnostics.
- `src/core/lsp_diagnostics.zig` (create): in-memory baseline store keyed by file
  URI; `setBaseline(uri, diags)`, `newSince(uri, current) -> []Diagnostic`.
  Register in `main.zig`.

**Approach.**
1. Add an LSP op `diagnostics` (args: `filePath`, optional `mode: baseline|check`).
   The server sends diagnostics as a `textDocument/publishDiagnostics`
   notification after `textDocument/didOpen`, NOT as a response to a request. So
   the handler must: initialize, `didOpen` the file, then read stdout until it
   sees a `publishDiagnostics` notification for that URI (or a short timeout).
2. Parse the diagnostics array (`range`, `severity`, `message`).
3. `mode=baseline`: store the parsed diagnostics in `lsp_diagnostics` keyed by URI
   and return a "baseline recorded: N diagnostics" summary.
4. `mode=check` (default): parse current diagnostics, diff against the stored
   baseline (a diagnostic is "new" if its `(line, severity, message)` tuple is not
   in the baseline set), and return the new ones (the "new errors" the reference
   surfaces). With no baseline, return all current diagnostics.
5. The baseline store is session-scoped in-memory (matches the reference's
   per-session tracking). No disk persistence.

**Acceptance criteria.**
- Write a test for `lsp_diagnostics.newSince`: baseline `[A,B]`, current `[A,B,C]`
  -> returns `[C]`; current `[A]` -> returns `[]`.
- Write a test that diagnostics-parse extracts `{line, severity, message}` from a
  synthesized `publishDiagnostics` JSON.
- `handleLsp` routes the `diagnostics` op (missing `filePath` -> clear error).
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Pure-function tests for the baseline diff and the diagnostics
parser (feed a captured `publishDiagnostics` JSON string) under
`tools/test_runner.zig`. The live `didOpen` -> notification read is verified
manually against zls.

**Risk / footguns.** `publishDiagnostics` is a notification (no `id`), so
`extractLspResult` (which looks for `"result"`) will NOT find it -- you need a
separate parser that scans for `"method":"textDocument/publishDiagnostics"`.
Servers may emit multiple diagnostics notifications (incremental); read for a short
bounded window and take the last one for the URI. Bounded timeout is essential or
the read loop hangs (no `result` ever arrives). Use the existing 512KiB read cap.

**Size.** L.

---

### Task 11 (tools-09): StructuredOutput tool for non-interactive structured JSON

**Goal.** Add a `StructuredOutput` tool that, in non-interactive (one-shot)
sessions, is auto-added to the tool set, accepts a caller-supplied JSON schema,
validates the model's output against it, and returns the structured object.

**Reference behavior + file:line.** `SyntheticOutputTool.ts:20`
(`SYNTHETIC_OUTPUT_TOOL_NAME='StructuredOutput'`), `:22-26`
(`isSyntheticOutputToolEnabled` = non-interactive only), `:50-65` (prompt +
passthrough call), `:116-163` (`createSyntheticOutputTool` compiles the
caller schema with ajv and validates input in `call`).

**Target Zig files.**
- `src/tools/structured_output.zig` (create): handler + a minimal JSON-schema
  validator (or reuse one if present). Register in `main.zig`.
- `src/tools/tool_schemas.zig` (edit): add the `StructuredOutput` schema. Mark it
  deferred normally, but it must be force-included in the tool set when the
  session is non-interactive AND a `--json`/response_schema is active.
- `src/tools/tool_dispatch.zig` (edit): dispatch entry + thread the active
  response schema to the handler.
- `src/session_mgmt.zig` (edit): in the one-shot/`--json` path, register the
  StructuredOutput tool with the caller's schema and treat its first call as the
  final structured result.
- `src/agent_runtime.zig` (read; reuse `pending_response_schema` at line 287 and
  the `--json` output path).

**Approach.**
1. The tool's input schema is dynamic: when a response schema is supplied
   (`--json <schema>` or `pending_response_schema`), the StructuredOutput tool's
   `json_schema` IS that caller schema. When none is supplied, accept any object
   (`{"type":"object"}`).
2. `isEnabled`: only add the tool when `!interactive` (one-shot). Plumb this:
   `collectSchemas` / the tool-registry builder should include StructuredOutput
   only in non-interactive mode. Add an `interactive` flag to the schema-collection
   call site (the runtime already knows `self.interactive`).
3. Handler `handleStructuredOutput`: validate the provided args against the caller
   schema (port a minimal validator: required keys present, types match for
   `string`/`number`/`boolean`/`array`/`object`/`integer`, enum membership). On
   mismatch, return a tool-error string `Output does not match required schema:
   <details>` so the model retries. On success, mark this as the final output:
   emit the validated JSON as the session's structured result.
4. `--json` integration: today `--json` outputs structured JSON at
   `session_mgmt.zig:410`. When StructuredOutput is active, the tool call IS the
   structured result -- capture its validated input and emit it as the final JSON,
   short-circuiting the normal text answer.
5. Prompt: `"Use this tool to return your final response in the requested
   structured format. You MUST call this tool exactly once at the end of your
   response to provide the structured output."` (verbatim from reference).

**Acceptance criteria.**
- Write a test: validator accepts an object matching a `{required:[a],
  properties:{a:string}}` schema and rejects one missing `a` or with wrong type.
- Write a test: StructuredOutput is present in the non-interactive tool set and
  absent in the interactive set.
- Write a test: a successful call's validated input is what gets emitted as the
  final JSON (factor the "extract final structured result" into a testable
  function).
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Unit-test the validator and the enable-gating and the
final-result extraction under `tools/test_runner.zig`. End-to-end `--json` flow is
verified manually (Verification).

**Risk / footguns.** Do not over-build the JSON-schema validator -- support only
the subset the reference's ajv usage actually exercises in practice (object/array,
required, basic types, enum). Anything fancier is speculative (CLAUDE.md rule 2).
The non-interactive gating must not leak the tool into interactive sessions (would
confuse the model). Reconcile with `--output-format json` naming: the survey notes
the reference flag is `--output-format json`; we already have `--json`. Keep `--json`
and treat `--output-format json` as an alias if cheap; otherwise note the deviation.

**Size.** L.

---

### Task 12 (tools-10): per-tool `max_result_size_chars` overrides

**Goal.** Let each tool declare its own artifact-persistence threshold (default the
global config value; Read = effectively unlimited; Grep tighter), instead of one
global threshold for all tools.

**Reference behavior + file:line.** `Tool.ts:457-466` (`maxResultSizeChars` doc,
default 100k), per-tool values: `GrepTool.ts:164` (20k), `FileReadTool.ts:342`
(Infinity), `toolExecution.ts:1413` (persist when result exceeds the per-tool cap).
The Read=Infinity exemption avoids a Read -> artifact-file -> Read loop.

**Target Zig files.**
- `src/core/types.zig` (edit): add `max_result_size_chars: usize = 0` to
  `ToolSchema` (0 = "use global default").
- `src/tools/tool_schemas.zig` (edit): set per-tool values -- Read/file_read =
  `std.math.maxInt(usize)` (never artifact), Grep = 20_000, others left 0.
- `src/agent_runtime.zig` (edit): `historyOutputForToolResult` (line 2716) looks
  up the per-tool threshold by `tool_name` instead of using the global value
  directly.

**Approach.**
1. Add the field (defaulted, zero-impact on existing literals).
2. Add `fn maxResultSizeForTool(tool_name) -> usize`: scan `builtin_schemas` for a
   matching name (use the same alias-aware matching dispatch uses), return its
   `max_result_size_chars` if non-zero, else `cfg.tool_output_artifact_threshold_bytes`.
   `maxInt(usize)` means never artifact.
3. `historyOutputForToolResult`: replace
   `const threshold = self.cfg.tool_output_artifact_threshold_bytes;` with
   `const threshold = maxResultSizeForTool(tool_name, self.cfg);`. The existing
   `threshold == 0 or output.len <= threshold` guard already handles "no
   artifacting" when threshold is huge.
4. Read exemption is the key behavior: a Read result is never persisted to an
   artifact and re-Read.

**Acceptance criteria.**
- Write a test: `maxResultSizeForTool("Read", cfg)` == `maxInt(usize)`;
  `maxResultSizeForTool("Grep", cfg)` == 20_000;
  `maxResultSizeForTool("WebFetch", cfg)` == the global default (0-fallback).
- Write a test: `historyOutputForToolResult` with a large Read output does NOT
  produce a `[tool_output_artifact]` block (Read is exempt), while the same-size
  output for a generic tool DOES (when over global threshold).
- `zig build -Doptimize=ReleaseFast` passes.

**Test strategy.** Unit tests in `agent_runtime.zig` (or a small helper module)
under `tools/test_runner.zig`. Construct a minimal `AgentRuntime`/cfg fixture, or
extract `maxResultSizeForTool` as a free function for direct testing.

**Risk / footguns.** `maxInt(usize)` + the `output.len <= threshold` comparison is
always true -> never artifacts; verify no overflow elsewhere uses the threshold in
arithmetic. The alias matching must agree with `dispatch` (Read vs file_read vs
read) so the override applies regardless of which alias the model used.

**Size.** M.

---

### Task 13 (tools-12): per-tool `output_schema` declaration + structured-content envelope

**Goal.** Add an `output_schema` field to `ToolSchema` so tools can advertise the
shape of their structured output, and (minimally) carry that schema through to the
model/SDK. Full `mcpMeta`/`structuredContent` passthrough is the SDK-grade form;
scope the core deliverable to the schema declaration + advertising it, and treat
the structured-result envelope as an optional extension.

**Reference behavior + file:line.** `Tool.ts:321-336`
(`ToolResult.mcpMeta`/`structuredContent`), `:400` (`outputSchema`),
`WebFetchTool.ts:32-46` (a concrete `outputSchema`). The reference threads
structured output to SDK consumers and passes MCP `_meta` through.

**Target Zig files.**
- `src/core/types.zig` (edit): add `output_schema: []const u8 = ""` to
  `ToolSchema`.
- `src/tools/tool_schemas.zig` (edit): set `output_schema` on tools that have a
  well-defined structured result (WebFetch: `{bytes, code, result, url}`;
  WebSearch: `{query, results}`; ToolSearch: `{matches, query,
  total_deferred_tools}`). Update `collectSchemas`/`freeSchemas` dup/free.
- (Optional extension) `src/tools/tool_dispatch.zig` + `src/agent_runtime.zig`: a
  `ToolResult` struct `{ text: []u8, structured: ?[]u8, meta: ?[]u8 }` that
  handlers can return instead of bare `[]u8`, surfaced for MCP `structuredContent`.

**Approach.**
1. Add the field (defaulted). Wire dup/free in `collectSchemas`/`freeSchemas`
   mirroring `usage_hint`.
2. Populate `output_schema` on the 3-4 tools with a stable structured result.
   These are advertised in the tool definition so SDK/MCP consumers know the shape.
3. Optional (defer if time-boxed): introduce a `ToolResult` envelope. Today every
   handler returns `[]u8` (`tool_dispatch.zig:83`). A non-breaking path: add an
   optional sidecar map (`tool_name -> structured_json`) that MCP-tool handlers can
   populate, surfaced only on the MCP/SDK boundary. Do NOT rewrite all 60+ handler
   signatures (that violates "surgical changes"); the envelope is opt-in.

**Acceptance criteria.**
- Write a test: WebFetch schema has a non-empty `output_schema` that parses as
  valid JSON.
- Write a test: `collectSchemas`/`freeSchemas` round-trip `output_schema` with no
  leak (leak-checking allocator).
- `zig build -Doptimize=ReleaseFast` passes (all `ToolSchema` literals compile).

**Test strategy.** Unit tests in `tool_schemas.zig` under `tools/test_runner.zig`.

**Risk / footguns.** Resist rewriting handler return types -- the survey itself
flags this as "mostly matters for SDK structured output." Keep the core change to
the declarative field + dup/free symmetry; the runtime envelope is explicitly
optional. Combine the dup/free edits with Task 6 and Task 12 (all three add a
defaulted `[]const u8` / `usize` field to `ToolSchema` and touch the same
`collectSchemas`/`freeSchemas` functions) so the struct + serialization is touched
once.

**Size.** L (S if the optional envelope is deferred).

---

## Verification

Build, install, and verify per CLAUDE.md after the phase is complete.

1. **Tests.** Run the full suite under the custom runner:
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build test
   ```
   All new unit tests (web prompt decision, redirect host compare, domain filters,
   AskUserQuestion parser, ToolSearch scoring, ConfigTool read/write, LSP routing,
   diagnostic diff, StructuredOutput validator, per-tool threshold lookup, schema
   field round-trips) must pass. New modules must appear in the `src/main.zig`
   comptime block so the runner discovers their tests.

2. **Release build + install** (CLAUDE.md, with the macOS ad-hoc-signature
   footgun handled by `rm -f` first):
   ```
   /Users/example/.local/zig/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
   rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode
   ```
   Bump `.version` patch in `build.zig.zon`.

3. **Manual checks.**
   - WebFetch with a prompt: `zcode -p 'WebFetch https://ziglang.org with prompt "what is the latest stable release"'` returns a focused answer, not a wall of stripped HTML. Without a prompt, behavior is unchanged.
   - Redirect: fetch a URL known to cross-host redirect (e.g. an `http://`-to-`https://`-different-host shortener) and confirm the `REDIRECT DETECTED:` message naming both URLs.
   - WebSearch domain filter: a search with `blocked_domains` excludes those hosts from the rendered results.
   - AskUserQuestion: trigger a 2-question multi-option prompt (one multiSelect) and confirm the TUI renders header chips, option descriptions, and a working multi-select; confirm per-question answers come back.
   - ToolSearch: `select:Read,Edit` returns both; a keyword query like `fetch web` ranks WebFetch first; `+slack send` (with an MCP slack server configured) pre-filters to slack tools.
   - ConfigTool: a read (`Config setting=theme`) returns the value; a write asks for approval and applies.
   - LSP: against a `.zig` file with `zls` installed, run `workspaceSymbol`, `prepareCallHierarchy`, `incomingCalls`, `outgoingCalls`, and `diagnostics` (baseline then check after introducing an error).
   - StructuredOutput: `zcode -p '...' --json '<schema>'` produces validated JSON; a model output violating the schema produces the schema-mismatch retry message.
   - Per-tool threshold: a Read of a >threshold file is returned inline (not artifacted); a generic large tool output IS artifacted.

4. **Wiki checkpoint.** Record in `wiki/` the non-obvious lessons: the curl
   `--write-out` multi-field marker (status + effective URL + content-type), the
   LSP call-hierarchy two-step interactive JSON-RPC requirement, the
   `publishDiagnostics`-is-a-notification gotcha, and the shared `ToolSchema`
   field-addition + dup/free symmetry pattern.

## Out-of-scope / deferred notes

- **`tool_reference` output blocks** (ToolSearch): the reference emits 1P-API
  `tool_reference` blocks (`ToolSearchTool.ts:444-470`). We keep our established
  inline `<functions>` JSON output. This is a provider-protocol feature, not a
  capability gap. Deferred deliberately.
- **WebFetch domain-blocklist preflight** (`utils.ts:176-203`, the
  `api.anthropic.com/api/web/domain_info` call): a cloud-coupled feature. Out of
  scope -- our `egress.zig` SSRF/scheme defense is the local equivalent.
- **`mcpMeta`/`structuredContent` runtime envelope** (tools-12 optional
  extension): the declarative `output_schema` field ships in this phase; the
  full structured-result passthrough through every handler is deferred unless the
  MCP/SDK consumer story demands it, to avoid a 60-handler signature rewrite.
- **WebFetch 15-min LRU URL cache + hostname-keyed domain-check cache**
  (`utils.ts:61-83`): a performance optimization, not a parity capability.
  Deferred.
- **AskUserQuestion HTML preview validation** (`AskUserQuestionTool.tsx:158-175`,
  `validateHtmlPreview`): we support markdown/text previews; HTML-fragment preview
  validation is a UI-format-specific extension, deferred unless the TUI grows an
  HTML preview renderer.
- **ConfigTool `USER_TYPE==='ant'` gating + async validators**
  (`ConfigTool.ts`): we expose Config unconditionally as a deferred tool with a
  static supported-settings allowlist; the reference's internal-user gating and
  async setting validators are out of scope.
- **`--output-format json` exact CLI flag name**: we keep `--json`; aliasing
  `--output-format json` is a nice-to-have, noted in Task 11.
