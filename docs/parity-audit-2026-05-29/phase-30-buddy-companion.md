# Phase 30: Buddy / companion sprite system (out-of-scope, document)

## Overview

**What this is.** The reference (`/Users/example/Downloads/claude-code-main/src/buddy/`) ships a gamified, time-boxed "companion" pet: a seeded-PRNG generator rolls a deterministic creature (rarity, species, eye glyph, hat, shiny flag, five stats) from `mulberry32(hash(userId + 'friend-2026-401'))`, an ASCII sprite of that creature animates beside the prompt input on a 500ms tick, the model is told (via a `companion_intro` prompt attachment) that a small pet sits beside the input and occasionally comments, a `/buddy` slash command hatches and pets it, and a rainbow `/buddy` teaser notification shows on startup only during the local-date window April 1-7 2026. The whole subsystem is compiled in or out behind a `feature('BUDDY')` bundle flag.

**Why it exists in the reference.** It is an April-Fools-style cosmetic with a marketing teaser window. It has zero functional value to a coding agent: it does not affect tool execution, planning, the agent loop, file edits, permissions, or any user-facing capability. The only place it touches real behavior is a single prompt attachment whose sole purpose is to keep the model from talking over the pet's speech bubble.

**Why it is out of scope for zcode.** Three independent reasons, each sufficient on its own:

1. **It is a decorative TUI/UI feature.** Five of the twelve gaps (the sprite widget, speech bubble, pet animation, narrow-terminal layout math, and per-turn reaction overlay) are React/Ink components (`CompanionSprite.tsx`, 370 lines + a 514-line ASCII art table in `sprites.ts`). zcode renders the REPL through `src/cli/repl_render.zig` and has no equivalent animation/widget column beside the prompt.
2. **It depends on subsystems that are themselves out of scope.** The seed comes from `config.oauthAccount?.accountUuid` (OAuth account identity is out of scope) and the entire subsystem is gated by `feature('BUDDY')` from `bun:bundle` (a bundle-time mechanism zcode does not have; the closest analog, `src/core/feature_gates.zig`, has no `BUDDY` entry and is a runtime kill-switch, not a compile-time strip).
3. **The feature is not even fully reconstructable from the reference dir.** The actual hatch flow and the model call that generates the companion's "soul" (name + personality) live elsewhere in the reference, not in `buddy/`. The per-turn "observer" that sets the reaction string is also a separate hot path not present here. So even a faithful port would be guessing at the two pieces that give the pet its content.

**Dependencies on earlier phases (1-16).** None to build, because nothing here is being built. If a future decision ever reverses this, it would touch: config (the global config struct, analogous to phases that added config fields), the prompt/attachment pipeline (`src/core/prompt_engine.zig` / `context.zig`), the slash-command registry (`src/repl_commands.zig`), the REPL renderer (`src/cli/repl_render.zig`), and the startup notification path (`src/cli/repl.zig` welcome banner / `os_notify.zig`). It would also depend on an OAuth account identity (out of scope) for a stable seed.

**Effort.** Build effort: **zero** (document-only phase). For sizing reference if it were ever reversed, the reference is ~1,300 lines across 6 files, dominated by the 514-line `sprites.ts` ASCII art and the 370-line `CompanionSprite.tsx` widget. The orchestrator's per-gap sizes (S/M/L) below are kept for traceability but apply to a hypothetical port, not to this phase.

## Scope split

| Decision | Gaps | Reason |
| --- | --- | --- |
| **IN-SCOPE (build)** | none | No gap in this subsystem delivers functional value to a coding agent. There is nothing to build in Phase 30. |
| **OUT-OF-SCOPE (document)** | buddy-companion-01 through buddy-companion-12 (all 12) | Decorative gamification gated by a bundle flag we lack, seeded from an OAuth identity we lack, with content (soul generation, per-turn observer) that lives outside the reference `buddy/` dir and cannot be reconstructed. Locked decision: buddy/companion sprite system is out of scope. |

**Net: 0 in-scope, 12 out-of-scope.** This phase produces documentation of the deviation only. The "Implementation tasks" section is intentionally empty per the structure (no in-scope gaps); all detail lives under "Documented deviations".

## Gaps covered

| id | title | severity | size | our current state |
| --- | --- | --- | --- | --- |
| buddy-companion-01 | Seeded-PRNG deterministic companion generator (mulberry32 + hash(userId+SALT)) | low | M | Absent. No `mulberry32`, no `hashString(userId+SALT)` roller, no rarity/species/eye/hat/stats roll, no `rollCache`, no soul+bones merge. `src/core/rng.zig` only wraps `std.Io.random`/`randomSecure`; `src/core/word_slug.zig` takes a `std.Random` for plan-ID slugs, not entity cosmetics. Verified. |
| buddy-companion-02 | Companion taxonomy: 18 species, 6 eyes, 8 hats, 5 rarities, 5 stats | low | S | Absent. No `SPECIES`/`EYES`/`HATS`/`STAT_NAMES`, no `RARITY_WEIGHTS`/`RARITY_STARS`/`RARITY_COLORS`, no `CompanionBones`/`Soul`/`StoredCompanion` types. Verified. |
| buddy-companion-03 | ASCII sprite rendering (18x3 frames, hat overlay, eye substitution, renderFace) | low | L | Absent. No `BODIES`/`HAT_LINES`/`renderSprite`/`spriteFrameCount`/`renderFace`. `repl_spinner.zig` only has thinking-spinner verbs ("Hatching", "Honking"), no creature sprites. Verified. |
| buddy-companion-04 | Live animated sprite widget beside the prompt (500ms tick, idle/blink/fidget) | low | L | Absent. `repl_render.zig` renders input + footer + transcripts only; no widget column, no `TICK_MS`/`IDLE_SEQUENCE`, no frame sequencing beside the prompt. Verified. |
| buddy-companion-05 | Companion speech bubble + per-turn reaction (10s show, 3s fade, fullscreen float) | low | M | Absent. No `BUBBLE_SHOW`/`FADE_WINDOW`/`SpeechBubble`/`CompanionFloatingBubble`/`companionReaction`. The per-turn observer that feeds reactions is not even in the reference `buddy/` dir. Verified. |
| buddy-companion-06 | /buddy pet interaction + heart-burst animation | low | S | Absent. No `companionPetAt`, `PET_BURST_MS`, `PET_HEARTS`, no heart-burst rendering, no fidget cycling. Verified. |
| buddy-companion-07 | /buddy slash command (hatch + pet) and command registration | low | M | Absent. No `/buddy` in `src/repl_commands.zig`, not in `removed_commands.zig`, not in `cc_stub_commands.zig`. The actual hatch + soul-gen model call are not in the reference `buddy/` dir. Verified. |
| buddy-companion-08 | Companion intro attachment / watcher persona injected into model context | low | S | Absent. No `companion`/`companionMuted` config fields, no `companion_intro` attachment type, no injection in `prompt_engine.zig`/`context.zig`. The three `companion` hits in src are unrelated comments. Verified. |
| buddy-companion-09 | April 1-7 2026 rainbow /buddy teaser startup notification | low | S | Absent. No `isBuddyTeaserWindow`/`isBuddyLive`/teaser notification, no April date-gating in startup. Welcome banner (`src/cli/repl.zig`) shows workspace/model/safety/proposals/init-nudge only. Verified. |
| buddy-companion-10 | feature('BUDDY') bundle flag gating the entire subsystem | low | S | Absent. `src/core/feature_gates.zig` lists `mcp_tool_bridge`, `browser_bridge`, `preprocessor`, `prompt_cache_hints`, `instruction_imports`, `cloud_telemetry`, `control_plane_policy_sync`, `control_plane_managed_settings_sync`; no `BUDDY`. It is a runtime kill-switch, not a bundle-time strip. Verified. |
| buddy-companion-11 | Companion persistence in global config (stored soul, regenerated bones) | low | S | Absent. No `config.companion`/`companionMuted`/`hatchedAt`, no `StoredCompanion`, no `companionUserId()` (which in the reference prefers `oauthAccount.accountUuid`). Verified. |
| buddy-companion-12 | Sprite layout math: reserved columns, narrow-terminal collapse, footer focus | low | M | Absent. No `companionReservedColumns`, no `MIN_COLS_FOR_FULL_SPRITE`, no narrow-terminal one-line collapse, no `footerSelection==='companion'`. `repl.zig`'s `footer_row_selection` renders tasks/teams/bridge/agent/tmux/worktree states only. Verified. |

## Implementation tasks

**None.** This phase has no in-scope gaps. All twelve gaps are documented deviations (see below). There is intentionally no Zig code, no new `core/` module, no `src/main.zig` comptime registration, and no test to write for Phase 30. This section is left empty by design so the roadmap reader can see at a glance that the phase is document-only.

## Documented deviations

All twelve gaps are deviations. Listed below grouped by the layer they live in, with what each is, why it is out of scope, and whether any local stub is worth doing. The short answer for stubs across the board is **no** - building any piece in isolation produces dead code (no widget to draw the sprite, no command to hatch it, no identity to seed it, no model call to give it a soul).

### Generator and taxonomy (data + logic layer)

- **buddy-companion-01 - Seeded-PRNG generator.** `companion.ts:16` `mulberry32`, `:27` `hashString` (FNV-1a fallback / `Bun.hash`), `:84` `SALT='friend-2026-401'`, `:91` `rollFrom`, `:107` `roll` cache, `:127` `getCompanion` (merges stored soul + regenerated bones; bones never persist so editing config cannot fake a rarity). Out of scope: the seed is `companionUserId()` -> `config.oauthAccount?.accountUuid` (OAuth out of scope), and the result only feeds the sprite/widget that is itself out of scope. **No stub.** Note: `src/core/word_slug.zig` already demonstrates the seeded-`std.Random` pattern zcode would use if this were ever built, and `src/core/rng.zig` already wraps both crypto and non-crypto RNG - so the primitive exists, only the entity generator does not. Reimplementing `mulberry32` exactly would matter only for cross-implementation determinism with the reference, which is not a goal.
- **buddy-companion-02 - Taxonomy tables.** `types.ts:54` `SPECIES` x18, `:76` `EYES` x6, `:79` `HATS` x8, `:91` `STAT_NAMES` x5, `:126/:134/:142` rarity weights/stars/colors, `:101/:111/:124` Bones/Soul/StoredCompanion split. Out of scope: pure cosmetic data tables. **No stub.** Reference-only quirk worth recording: the 18 species are constructed at runtime via `String.fromCharCode` (`types.ts:14`) specifically so the literal species strings stay out of the build output, because one species name collides with a model-codename canary in the reference's `excluded-strings.txt` build-time grep. That is a reference-build concern with no analog in zcode and must not be copied if this is ever revisited.

### Rendering and UI (TUI/React layer - the bulk of the deviation)

- **buddy-companion-03 - ASCII sprite rendering.** `sprites.ts:26` `BODIES` (18 species x 3 idle frames, 5 lines x 12 cols), `:443` `HAT_LINES` (8 overlay lines), `:454` `renderSprite` (substitutes `{E}`->eye glyph, overlays hat on a blank line 0, trims the blank hat slot when all frames allow), `:471` `spriteFrameCount`, `:475` `renderFace` (one-line compact face per species). Out of scope: ~514 lines of hand-drawn ASCII art with no functional purpose. **No stub.**
- **buddy-companion-04 - Live animated sprite widget.** `CompanionSprite.tsx:16` `TICK_MS=500`, `:23` `IDLE_SEQUENCE=[0,0,0,0,1,0,0,0,-1,0,0,2,0,0,0]`, `:176` `CompanionSprite`, `:242-258` frame selection + blink. Out of scope: decorative animation ticking beside the prompt; zcode's `repl_render.zig` has no widget column and no per-frame ticking loop for the input row. **No stub.**
- **buddy-companion-05 - Speech bubble + per-turn reaction.** `CompanionSprite.tsx:17` `BUBBLE_SHOW=20` (~10s), `:18` `FADE_WINDOW=6` (~3s dim), `:43` `SpeechBubble`, `:205-214` 10s clear timer, `:286-289` inline bubble, `:296` `CompanionFloatingBubble` (fullscreen overlay). Out of scope: cosmetic, and the per-turn observer that sets the reaction string is not in the reference `buddy/` dir at all. **No stub.**
- **buddy-companion-06 - /buddy pet + heart-burst.** `CompanionSprite.tsx:19` `PET_BURST_MS=2500`, `:27` `PET_HEARTS` (5 frames), `:222-223` petAge/petting, `:243/:259` heartFrame prepended. State backed by `companionPetAt` (in the reference's app state store, also outside `buddy/`). Out of scope: pure gamification. **No stub.**
- **buddy-companion-12 - Sprite layout math.** `CompanionSprite.tsx:167` `companionReservedColumns` (tells PromptInput how many columns the sprite + inline bubble consume so text wraps correctly), `:227-241` narrow-terminal collapse to a one-line face (quip replaces name when speaking), `:179` `footerSelection==='companion'`, `:266-273` focus/inverse-name row. Out of scope: layout plumbing whose only job is to host the cosmetic sprite; with no sprite there are no columns to reserve. zcode's `footer_row_selection` (in `src/cli/repl.zig`) already enumerates its real targets (tasks/teams/bridge/agent/tmux/worktree) and would simply never gain a `companion` target. **No stub.**

### Command, prompt, and notification (integration layer)

- **buddy-companion-07 - /buddy slash command.** `useBuddyNotification.tsx:79` `findBuddyTriggerPositions` matches `/\/buddy\b/`; `:11` "Command stays live forever after"; `CompanionSprite.tsx:19` references `/buddy pet`. Out of scope: the user-facing entry point of the cosmetic. **No stub.** Important: the actual hatch flow and the soul-generation model call are not present in the reference `buddy/` dir (they live elsewhere), so the full command cannot be reconstructed from these files even if someone wanted to.
- **buddy-companion-08 - Companion intro attachment / watcher persona.** `prompt.ts:7` `companionIntroText`, `:15` `getCompanionIntroAttachment`, `:18` `feature('BUDDY')` gate, `:20` `companionMuted` gate, `:22-27` dedup by companion name. This is the **only** piece that touches the real model prompt: it injects a `companion_intro` attachment telling the model "a small `<species>` named `<name>` sits beside the input and occasionally comments; you are a separate watcher; answer in <=1 line when the user addresses the pet by name." Out of scope: it exists solely to support the cosmetic persona, depends on `getCompanion()` (gap 01/11) and a `companion_intro` attachment type zcode does not have. **No stub** - injecting this persona with no pet to back it would actively confuse the model.
- **buddy-companion-09 - April 1-7 2026 teaser notification.** `useBuddyNotification.tsx:12` `isBuddyTeaserWindow` (local date, year 2026 / month index 3 / date <= 7), `:17` `isBuddyLive`, `:43` `useBuddyNotification` (rainbow `/buddy`, priority immediate, 15s timeout, only if no companion hatched), `:13/:18` `"external"==='ant'` branch force-enables for internal builds. Out of scope: a time-boxed marketing teaser tied to a specific 2026 April-Fools window. **No stub.**

### Gating and persistence (config layer)

- **buddy-companion-10 - feature('BUDDY') bundle flag.** Guards at `prompt.ts:18`, `useBuddyNotification.tsx:53/:83`, `CompanionSprite.tsx:168/:215/:340`. Out of scope: it is the bundle-time compile-in/out gate for an out-of-scope feature; with the feature gone there is nothing to gate. zcode's `src/core/feature_gates.zig` is a runtime kill-switch list and deliberately has no `BUDDY` entry. **No stub** - adding a dead gate entry would be a no-op pointing at nothing.
- **buddy-companion-11 - Config persistence.** `types.ts:124` `StoredCompanion` (`{ name, personality, hatchedAt }`); `companion.ts:119` `companionUserId()` prefers `config.oauthAccount?.accountUuid`, falls back to `config.userID ?? 'anon'`; `:127` `getCompanion` reads `getGlobalConfig().companion`; `prompt.ts:20` `companionMuted`. Out of scope: stores only the model-generated soul (bones regenerate from `hash(userId)` on every read so renames and array edits cannot break stored companions and users cannot edit their way to a legendary). Depends on the OAuth `accountUuid` for its seed (out of scope), so even a stub would need a `userID` substitute. **No stub.**

## Verification

This is a documentation-only phase, so verification confirms that **nothing was built and nothing regressed**, not that a feature works.

1. **No new code introduced.** Confirm the working tree has no buddy/companion/sprite source. The repo is clean and these symbols are absent (verified during planning): `grep -rin "mulberry32\|hashString\|companion_intro\|CompanionBones\|PET_HEARTS\|BUDDY\|isBuddyTeaserWindow\|companionReservedColumns" src/` should return only the three unrelated comment hits already known (`src/core/context.zig:1071`, `src/tools/shell.zig:428`, `src/repl_commands.zig:1881`) and nothing else.
2. **Build still passes (sanity, since no code changed):**
   - `zig build -Doptimize=ReleaseFast`
   - Install per CLAUDE.md (fresh inode to keep the ad-hoc signature valid): `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`
3. **Manual checks (confirm the feature is genuinely absent, as expected):**
   - `zcode` startup shows the normal welcome banner (workspace/model/safety/proposals/init-nudge) with no rainbow `/buddy` teaser, on any date.
   - Typing `/buddy` in the REPL is not a recognized command (it is absent from the `src/repl_commands.zig` registry, `removed_commands.zig`, and `cc_stub_commands.zig`).
   - The prompt input renders with no animated widget, sprite column, or speech bubble beside it.
4. **Version bump.** Per CLAUDE.md, bump the patch in `build.zig.zon` for the doc change so the user-facing `X.Y.Z+<hash>` advances; `build.zig` appends the git short-hash automatically (do not touch `computeVersionString`).
5. **Roadmap consistency.** Confirm `docs/PARITY_ROADMAP_V2.md` lists Phase 30 as out-of-scope / document-only with 0 in-scope gaps, matching the Scope split table above.

**Reopen criteria (when this deviation should be revisited).** Only if all three of these become true: (a) the locked "buddy out of scope" decision is reversed, (b) zcode gains a stable per-user identity to seed from (OAuth `accountUuid` or an equivalent), and (c) the reference's hatch flow + soul-generation model call (currently outside `buddy/`) become available to port. Absent all three, Phase 30 stays document-only.
