# Project Wiki - Schema and Operating Rules

This folder is a **living knowledge base** for THIS project, maintained by Claude. Inspired by Andrej Karpathy's "LLM Wiki" pattern. Separate from the global wiki at `~/llm-wiki/`.

## What belongs here vs global wiki

**Here (project wiki):** architecture, decisions, domain rules, this codebase's gotchas, team conventions, runbooks, external API quirks SPECIFIC to how this project uses them.

**Global wiki (`~/llm-wiki/`):** language quirks, library gotchas, personal preferences, debugging patterns, anything transferable across projects.

If in doubt, ask: "would this help me in a completely different project?" Yes -> global. No -> here.

## Layout

```
wiki/
├── CLAUDE.md        # this file
├── index.md         # auto-maintained topic-organized TOC
├── log.md           # append-only chronological record of ingests
├── sources/         # raw inputs: docs, transcripts, post-mortems, specs
├── pages/           # synthesized knowledge. ONE concept per file.
│   ├── architecture.md  # seed stub, update as the project stabilizes
│   ├── decisions/       # one file per non-trivial decision + its WHY
│   ├── gotchas/         # one file per gnarly bug, footgun, or surprise
│   └── runbooks/        # one file per operational procedure
└── templates/
    └── page.md      # starter template with frontmatter
```

Rules:
- `sources/` is immutable once a file is added. Never edit a source.
- `pages/` is the product. Every claim must be traceable to a source or to direct code evidence (cite file paths with line numbers).
- `index.md` and `log.md` update after every ingest.

## The three operations

### 1. INGEST
Trigger: "ingest X", "add X to the wiki", "process this".
1. Read the source.
2. Extract facts, decisions, gotchas.
3. For each: update existing page or create new one using `templates/page.md`. Kebab-case filenames.
4. Add `[[wikilinks]]` between related pages.
5. Update `index.md`. Append one line to `log.md` (date, source, pages touched, one-line summary).
6. Report: what was ingested, pages created/updated, flagged contradictions or gaps.

### 2. QUERY
Trigger: "what do I know about X", "query X", "recall X".
1. Search `pages/` first. Only open `sources/` if a page cites one and more detail is needed.
2. Answer with citations to `[[page-name]]` or `sources/...` or `src/file.ext:line`.
3. If the wiki has nothing: say so. Do NOT answer from general knowledge without labeling it.
4. Flag contradictions or gaps at the end.

### 3. LINT
Trigger: "lint the wiki", "health check", "find issues".
1. Orphan pages (no incoming or outgoing wikilinks).
2. Broken wikilinks.
3. Stale citations (sources that no longer exist, or code paths that no longer exist).
4. Contradictions between pages.
5. Pages missing from `index.md`.
Report a punch list. Do NOT auto-fix.

## Page format

```markdown
---
title: Short Title
tags: [architecture, decision, gotcha, runbook, domain]
created: YYYY-MM-DD
updated: YYYY-MM-DD
sources:
  - sources/filename.ext
  - src/path/to/file.ext:line (for code evidence)
---

# Short Title

## Summary
2-5 sentence summary.

## Key points
- Bullet points of core facts.

## Details
Longer prose, examples, code references.

## Related
- [[other-page]] - one-line on why it's related

## Sources
- sources/filename.ext - one-line context
```

Conventions:
- Kebab-case filenames, no spaces, no dates in filename.
- Obsidian `[[wikilinks]]` for inter-page refs.
- ISO dates `YYYY-MM-DD`.
- NO em dashes or en dashes anywhere. Use `-` or `--`.

## What NOT to do

- Do not invent facts. Every claim must have a source or a cited line of code.
- Do not document current implementation details of fast-moving code (they rot). Stay at "intent and invariants" abstraction.
- Do not delete pages without explicit user approval.
- Do not edit `sources/`.
- Do not auto-ingest. Always ask first.
- Do not duplicate knowledge that belongs in the global wiki.
