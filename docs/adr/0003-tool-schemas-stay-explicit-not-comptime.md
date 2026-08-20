# Tool schemas/handlers stay explicit, not comptime-derived

**Status:** accepted

An architecture review flagged that each tool is "defined in three places" --
`src/tools/tool_schemas.zig` (the JSON wire schema), `src/tools/tool_descriptions.zig`
(the prose), and `src/tools/tool_dispatch.zig` (the ~65 `handleX` arg-extraction
functions) -- and suggested a single source of truth per tool: a Zig arg struct
per tool with a comptime-derived JSON schema, description, and dispatch.

We keep the explicit three-part form.

## Why

1. **The handlers encode load-bearing arg-tolerance, not boilerplate.** The
   dispatch handlers do real per-tool work: they accept arg-name synonyms that
   real models emit (e.g. `handleShell` accepts both `run_in_background` and the
   model-preferred `background`; timeout accepts `timeout_seconds`,
   `timeout_ms`, and `timeout`), with comments documenting bugs these synonyms
   fixed. A comptime schema-to-struct mapping would have to re-encode every
   alias and fallback as custom field metadata -- *more* complex than the
   explicit handlers, and easy to regress.
2. **The hand-written JSON schemas carry tuned per-field descriptions and
   `required` arrays** that guide the model. Deriving these from Zig types
   needs a metadata sidecar that ends up as verbose as the JSON it replaces.
3. **The split is a conventional, readable separation** (schema data / prose /
   behaviour), not one concept artificially fragmented. Schemas change rarely,
   so the drift risk the proposal targets is low.

## Consequence

Future reviews should not re-suggest comptime schema generation for tools. When
adding a tool, add its entry to `builtin_schemas`, its prose to
`tool_descriptions.zig`, and its handler to `tool_dispatch.zig` -- and make the
handler forgiving about arg-name synonyms, which is the point of keeping it
explicit.
