---
title: Native mode still needs minimal steering nudges
tags: [gotcha, agent-loop]
created: 2026-05-25
updated: 2026-05-26
sources:
  - src/agent_runtime.zig:1407 (native_mode no-tool-call branch)
  - src/agent_tools.zig:1679 (looksLikeBlatantActionNarration)
  - src/agent_tools.zig:1735 (looksLikeQuestionStall) -- added 0.11.72, hardened 0.11.73
  - PRD #533 (the change that dropped nudges in native mode)
---

# Native mode still needs minimal steering nudges

## Summary
PRD #533 ("end_turn means end_turn") removed ALL nudges from the
native Anthropic tool path on the assumption that capable models
always emit their tool call in the same turn -- if they don't, that
is the real final answer.

This is **wrong in two narrow but reproducible cases** even on Claude
Sonnet 4-6, and each one needs a targeted re-add. Treat the list
below as the canonical set; do not blanket-restore the old non-native
nudges.

## Cases where a no-tool-call response is NOT a real end of turn

1. **Action-narration stall** (re-added in 0.11.70).
   Text like "Let me research it first", "I'll create X" with no tool
   call. The model announced the action and stopped. Detected by
   [`looksLikeBlatantActionNarration`](../../../src/agent_tools.zig)
   (short preamble starting with "let me", "i'll", "going to", ...).
   Nudge: "you described an action but did not emit a tool_call".

2. **Question-narration stall** (re-added in 0.11.72; hardened in 0.11.73).
   Text like "Before diving in, I need to clarify a few things to
   build this right." with no `?` in the response. The model
   announced clarifying questions but listed none, so the turn ends
   as input-needed with literally nothing for the user to answer.
   Detected by [`looksLikeQuestionStall`](../../../src/agent_tools.zig)
   (short preamble matching "before diving in", "i need to clarify",
   "i need a few details", "i have a few questions", "to build this
   correctly", ... AND no `?` anywhere in the text). A response that
   DOES contain a `?` is a legitimate question turn and must NOT match.

   Three guards needed -- learned the hard way in 0.11.73 after
   0.11.72's single-attempt-shared-cap version let Sonnet 4-6 burn
   4 rounds (128k tokens) rephrasing the same announcement:

   - **Separate cap of 2**, not the shared cap of 4. Extra retries
     do not help with this failure mode; the model just produces
     variations of the same announcement.
   - **Escalating nudge**. Attempt 1: polite list-or-tool ask.
     Attempt 2: forceful "STOP RESTATING THE SAME ANNOUNCEMENT.
     Next response MUST be a tool_call (AskUserQuestion or Write)."
   - **Identical-response break**. If the new assistant text is
     byte-equal to the one we just nudged on, give up immediately --
     a verbatim repeat will not change on attempt 2 either.

3. **Truncation** (always kept). `response.truncated` with up to 5
   continuations; bypasses everything else.

## Why the heuristics matter
Both stalls produce a deadlock the user cannot escape without
re-typing -- there is no "?" for them to answer (#2) and no
visible "tool failed" status (#1). They look like the agent gave up
mid-thought. Re-adding a bounded, specific nudge per pattern is
cheaper than the alternatives (always-on nudges = back to the
overcorrection PRD #533 fixed; relying on the model to recover = it
doesn't).

## When you add a new stall pattern
Same shape every time:
1. Add a `looksLikeXxxStall(text)` helper next to the existing ones
   in `src/agent_tools.zig` -- length-capped, cue list, short-circuit
   on signs the text is actually a real answer.
2. Wire it into the `if (native_mode) { ... }` block in
   `src/agent_runtime.zig` BEFORE the broader action-narration check
   if its nudge message differs.
3. Use a **separate counter** with a **tight cap (1-2)** unless you
   have evidence extra retries actually recover. Sharing
   `action_reprompt_attempts` was the 0.11.72 mistake.
4. Escalate the nudge between attempts and add an identical-response
   break -- two different forms of the same loop-protection.
5. Add three tests: "fires on the stall", "does NOT fire on the real
   answer", and "fires on at least one rephrased variation observed
   in the wild". The false-positive case is the one that breaks
   normal conversation.

## Related
- [[anthropic-prompt-caching]] -- the native mode this guards is the
  one that benefits from prompt caching.
