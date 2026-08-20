# Per-tool max_result_size_chars (artifact threshold) override

Phase 9 / tools-10. Each `ToolSchema` (src/core/types.zig) carries
`max_result_size_chars: usize = 0` controlling when a tool's result is persisted
to a session artifact and reduced to a history preview.

Semantics of the value:

- `0` = "use the global default" (`cfg.tool_output_artifact_threshold_bytes`).
- `maxInt(usize)` = "never artifact". Set on `Read`/`file_read` so a large Read
  result is not written to an artifact file the model then has to Read again (a
  Read -> artifact -> Read loop). Mirrors FileReadTool.ts maxResultSizeChars =
  Infinity.
- A finite value (e.g. `Grep` = 20_000) caps tighter than the global default so
  repo-wide searches never flood history. Mirrors GrepTool.ts 20k.

## Lookup is alias-aware and must agree with the dispatch table

`tool_schemas.maxResultSizeForTool(tool_name, global_default)` resolves the
threshold by scanning `builtin_schemas`. The footgun: the dispatch table
(tool_dispatch.zig) maps several names to one handler
(`file_read`/`Read`/`read`, `Grep`/`grep`), but `builtin_schemas` only carries
the override on SOME spellings (`file_read`, `Read`, `Grep` have entries;
lowercase `read`/`grep` do NOT). So the lookup does:

1. exact-name pass over `builtin_schemas` (catches `file_read`, `Read`, `Grep`),
   then
2. a tiny explicit alias map (`read` -> `Read`, `grep` -> `Grep`) and retry.

If a future override is added to a tool whose lowercase/legacy alias has no
schema entry, extend that alias map or the override silently won't apply when the
model calls the alias. Keep the map minimal -- only tools that set a non-zero
override need an entry.

## The maxInt comparison is overflow-safe

`historyOutputForToolResult` guards with `threshold == 0 or output.len <= threshold`.
With `threshold == maxInt(usize)` the comparison is always true (no artifact) and
never does arithmetic on the threshold, so there is no overflow. Verify any new
code path that does arithmetic on the threshold handles maxInt.

## Field is a value type -- no dup/free needed

Unlike `usage_hint`/`search_hint` (`[]const u8`, dup'd in `collectSchemas` and
freed in `freeSchemas`), `max_result_size_chars` is a `usize` copied by value.
`collectSchemas` carries it through with a plain assignment; `freeSchemas` does
nothing for it. Do not add it to the free path.
