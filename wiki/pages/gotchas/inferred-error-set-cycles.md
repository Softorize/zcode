---
title: Inferred error-set dependency loops in agent_runtime
tags: [gotcha]
created: 2026-05-23
updated: 2026-05-23
sources:
  - src/agent_runtime.zig (runForkedSkill annotated anyerror)
---

# Inferred error-set dependency loops in agent_runtime

## Summary
Adding a new method to `AgentRuntime` that (even transitively) calls back into
`handlePrompt` / the tool-dispatch path can produce a Zig compile error:
`error: dependency loop with length N`. It happens because every function in the
chain uses an *inferred* error set (`!T`), and the new call closes a cycle the
compiler can't resolve. The fix is to give ONE function in the cycle an
*explicit* error set so inference has a fixed point to anchor on.

## Key points

- Symptom: `dependency loop with length 6` with a note chain like
  `executeToolCallDispatch -> tryExecuteSkillRun -> runForkedSkill ->
  handlePrompt -> handlePromptWithModeAndReporter -> ... -> executeToolCallDispatch`.
- Trigger seen: a forked-skill runner that builds a child `AgentRuntime` and
  calls `child.handlePrompt(...)`, invoked from the tool-dispatch path. The
  child-runtime call re-enters the same inferred-error chain.
- Fix: annotate the leaf-most offending function with `anyerror!T` instead of
  `!T`. Example: `fn runForkedSkill(...) anyerror![]u8`. One explicit error set
  anywhere in the loop breaks it; you do NOT need to annotate every function.
- This is a recurring shape in `agent_runtime.zig` because so much of it is
  mutually recursive through `handlePrompt`. When you add a method that loops
  back into the turn machinery and the build complains about a dependency loop,
  reach for `anyerror` on the new method first.

## Related
- [[test-discovery]] - another agent_runtime/build footgun

## Sources
- src/agent_runtime.zig - runForkedSkill carries an explicit `anyerror` set for this reason
