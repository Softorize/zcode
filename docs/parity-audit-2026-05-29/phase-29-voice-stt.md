# Phase 29: Voice input and streaming STT (out-of-scope, document)

## Overview

**What this phase covers.** The reference project (Claude Code) ships a hold-to-talk voice input mode: hold a key, speak, and the audio is captured from your microphone, streamed over a WebSocket to Anthropic's `voice_stream` speech-to-text (STT) endpoint, transcribed with coding-domain keyword biasing, and dropped into the prompt buffer as text. This phase audits that entire subsystem against zcode and produces a single decision: **the whole subsystem is out of scope, and zcode's existing honest stub is the correct deviation.** This document records the reasoning so a future session does not re-litigate it or accidentally start building a half-feature.

**Why it is out of scope.** The voice subsystem is structurally incompatible with zcode's design contract on three independent axes, any one of which is disqualifying:

1. **Cloud + OAuth lock-in.** The STT backend is `wss://.../api/ws/speech_to_text/voice_stream` on claude.ai, gated on a valid Anthropic OAuth access token. The reference code itself documents that this endpoint is "not available with API keys, Bedrock, Vertex, or Foundry" (`voiceModeEnabled.ts:33-35`). zcode is provider-agnostic and explicitly out-of-scope for Anthropic OAuth and first-party telemetry/GrowthBook (locked decisions in earlier phases). There is no provider-neutral local equivalent to point a stub at.
2. **Native audio dependency.** Capture requires a native cpal NAPI module (CoreAudio/AudioUnit on macOS, ALSA on Linux) or an external `sox`/`arecord`/`ffmpeg` binary. zcode's release posture is a small, self-contained native binary with a low dependency footprint; bundling a native audio stack or hard-depending on an external recorder binary violates that.
3. **GrowthBook feature gating.** Visibility is gated on `feature('VOICE_MODE')` plus the `tengu_amber_quartz_disabled` kill-switch and the `tengu_cobalt_frost` (Nova 3) flag, all served from Anthropic's GrowthBook. zcode has no GrowthBook client and the first-party phone-home it depends on is out of scope.

**Dependencies on earlier phases.** None to build. The phase only *references* infrastructure that already exists and is sufficient: the slash-command dispatch path (`repl_commands.zig`), the stub-command table (`core/cc_stub_commands.zig`), the feature-gate/kill-switch config surface (`core/config.zig`, `core/feature_gates.zig`), and the keybindings model (`cli/keybindings.zig`). Nothing in those phases needs a voice-shaped hook.

**Effort.** Build effort: **zero.** zcode already ships the honest deviation (a recognized `/voice` stub command with a test). The only work this phase warrants is documentation hygiene and a couple of optional defensive guards (see Documented deviations). Total realistic effort if every optional item is taken: **XS** (well under an hour, mostly verification).

## Scope split

| Decision | Items | Reason |
|---|---|---|
| **IN-SCOPE (build)** | *none* | Every gap depends on at least one locked out-of-scope pillar: Anthropic OAuth, native/external audio capture, or GrowthBook telemetry. No gap has a provider-agnostic, dependency-free local form worth shipping. |
| **OUT-OF-SCOPE (document)** | voice-stt-01 .. voice-stt-12 (all 12) | Documented below with the specific pillar each one violates. The existing `/voice` stub already communicates unavailability honestly; building partial scaffolding would either advertise a feature we do not ship (dishonest) or pull in a forbidden dependency. |

There are no in-scope implementation tasks in this phase. This is by design and is the correct parity posture: zcode reaches reliability/honesty parity by being truthful about what it does not do, not by file-for-file mimicry (per the roadmap's stated goal).

## Gaps covered

| id | title | severity | size | our current state |
|---|---|---|---|---|
| voice-stt-01 | Voice mode enablement gating (auth + GrowthBook kill-switch) | low | S | No `isVoiceModeEnabled`/`hasVoiceAuth`/`isVoiceGrowthBookEnabled`. No `VOICE_MODE`/`tengu_amber_quartz_disabled` flags. `/voice` is a static stub (`cc_stub_commands.zig:17`). |
| voice-stt-02 | `voice_stream` WebSocket STT client | low | L | Not implemented. No WebSocket STT client, no interim/final segmentation, no multi-trigger finalize. |
| voice-stt-03 | Native/fallback audio capture (cpal NAPI, SoX `rec`, ALSA `arecord`) | low | L | Not implemented. No mic capture, no SoX/arecord fallback, no PCM streaming, no device probing/WSL handling. |
| voice-stt-04 | Microphone availability + permission probing | low | M | Not implemented. No `checkRecordingAvailability`/`requestMicrophonePermission`/`checkVoiceDependencies`, no TCC trigger, no install hints. |
| voice-stt-05 | Voice keyterm biasing list (Deepgram keyword hints) | low | S | Not implemented. No `getVoiceKeyterms`, no `GLOBAL_KEYTERMS`, no `splitIdentifier`, no recent-file term collection. |
| voice-stt-06 | `/voice` toggle command with pre-flight checks | low | S | Static stub only (`cc_stub_commands.zig:17`), with a passing test (`cc_stub_commands.zig:55-57`). No toggle, no pre-flight checks, no settings persistence. |
| voice-stt-07 | Hold-to-talk capture state machine (`useVoice`) | low | L | Not implemented. No keypress/release-timer state machine, no streaming pipeline, no interim accumulation, no voice keybinding. |
| voice-stt-08 | STT dictation language normalization (BCP-47) | low | M | Not implemented. No `normalizeLanguageForSTT`, no `LANGUAGE_NAME_TO_CODE`. Note: `config.preferred_language` is *response* language, NOT STT dictation language. |
| voice-stt-09 | `VoiceModeNotice` availability banner | low | S | Not implemented. No banner, no `voiceNoticeSeenCount`. |
| voice-stt-10 | `voice:pushToTalk` keybinding (Space hold) | low | S | Not implemented. No `voice_pushToTalk` action in `BindingAction`; Space maps only to `confirm_toggle` in the Confirmation context. |
| voice-stt-11 | Voice config persistence fields (`voiceEnabled`, hint counters) | low | S | Not implemented. None of `voiceEnabled`/`voiceNoticeSeenCount`/`voiceLangHintShownCount`/`voiceLangHintLastLanguage` exist in `core/config.zig`. |
| voice-stt-12 | Voice analytics events (`tengu_voice_toggled`, etc.) | low | S | Not implemented. No voice analytics; no `tengu_voice_toggled`/`tengu_cobalt_frost`/`tengu_amber_quartz_disabled`. Doubly out of scope (voice + first-party telemetry). |

## Implementation tasks

**None.** There are no in-scope gaps in this phase, so there is nothing to implement. The remaining sections record the rationale and the small set of optional hygiene checks.

Per the project rule against speculative work and over-building: do not scaffold any voice module, config field, keybinding action, or feature flag. Every such artifact would be dead code with no reachable caller (the only caller in the reference is the audio pipeline, which we do not and will not have), and shipping `voiceEnabled`/`VOICE_MODE` flags would advertise a capability zcode does not provide.

## Documented deviations

Each item below is intentionally not built. Listed with the specific locked pillar it violates and whether any local stub is worth doing.

- **voice-stt-01 - Enablement gating.** Violates the OAuth pillar (`hasVoiceAuth` needs a valid Anthropic OAuth access token) and the GrowthBook pillar (`isVoiceGrowthBookEnabled` reads `tengu_amber_quartz_disabled`). Reference: `voiceModeEnabled.ts:16-54`. *Local stub:* none. The honest answer ("voice is unavailable") is already delivered by the `/voice` stub; a gating function that always returns false would be unused dead code.

- **voice-stt-02 - `voice_stream` WebSocket STT client.** Violates the OAuth + cloud pillar; the endpoint is claude.ai-only and not reachable with API keys/Bedrock/Vertex. Reference: `voiceStreamSTT.ts:36-175,322-543`. *Local stub:* none. There is no provider-agnostic STT we could substitute, so a stub client would connect to nothing.

- **voice-stt-03 - Native/fallback audio capture.** Violates the native-dependency pillar (cpal NAPI / `sox rec` / `arecord`). Reference: `voice.ts:24-36,335-525`. *Local stub:* none. Pulling in CoreAudio/ALSA or hard-depending on an external recorder contradicts the small-binary, low-dependency release posture.

- **voice-stt-04 - Mic availability + permission probing.** Violates the native-dependency pillar; only meaningful if capture exists. Reference: `voice.ts:190-328`. *Local stub:* none.

- **voice-stt-05 - Keyterm biasing list.** Sole consumer is the `voice_stream` endpoint (OAuth/cloud pillar). Reference: `voiceKeyterms.ts:13-106`. *Local stub:* none. The `splitIdentifier` helper (camel/kebab/snake/path split, drop fragments <=2 chars) is pure and generic, but it has **no other caller anywhere in zcode**, so extracting it standalone would be building an unused utility. Do not add it speculatively. If a future, unrelated feature needs identifier splitting, build it then, scoped to that feature.

- **voice-stt-06 - `/voice` toggle with pre-flight checks.** The command's entire purpose is enabling mic+STT (OAuth + native pillars). Reference: `commands/voice/voice.ts:16-150`. *Local stub:* **already shipped and correct.** `core/cc_stub_commands.zig:17` returns: "Voice input is unavailable in zcode: it needs microphone capture + a speech-to-text service this build does not bundle. Type your prompt instead." Dispatched via `repl_commands.zig:168-170`, covered by tests at `cc_stub_commands.zig:55-57`. No further work.

- **voice-stt-07 - Hold-to-talk state machine (`useVoice`).** Orchestrates mic capture + STT; both pillars. Reference: `hooks/useVoice.ts`. *Local stub:* none. Also depends on the React/Ink event model zcode does not use.

- **voice-stt-08 - STT dictation language normalization.** Feeds only the `voice_stream` `language` param (OAuth/cloud pillar). Reference: `hooks/useVoice.ts:42-130`. *Local stub:* none. **Rename-trap warning:** do NOT repurpose `config.preferred_language` (`core/config.zig:123`) for this. That field is the *model response* language ("Always respond in <lang>"), which is a different concept from STT *dictation input* language. They must not be conflated, and adding STT normalization on top of it would wrongly couple two unrelated settings.

- **voice-stt-09 - `VoiceModeNotice` banner.** Advertises a feature zcode does not ship; showing "Voice mode is now available - /voice to enable" would be dishonest. Reference: `components/LogoV2/VoiceModeNotice.tsx:1-60`. *Local stub:* none, by design.

- **voice-stt-10 - `voice:pushToTalk` keybinding.** The binding only triggers mic capture (native pillar), and it is registered only when `feature('VOICE_MODE')` is on (GrowthBook pillar). Reference: `keybindings/defaultBindings.ts:91-96`. *Local stub:* none. Do not add a `voice_pushToTalk` action to `BindingAction` in `cli/keybindings.zig`; it would have no handler. Note Space is already bound to `confirm_toggle` in the Confirmation context, so even adding it would risk a binding collision for zero benefit.

- **voice-stt-11 - Voice config persistence fields.** These fields (`voiceEnabled`, `voiceNoticeSeenCount`, `voiceLangHintShownCount`, `voiceLangHintLastLanguage`) exist only to support the mic+STT feature and its notice/hint throttling. Reference: `utils/config.ts:338-340`; `commands/voice/voice.ts:127-145`. *Local stub:* none. Do not add them to `core/config.zig`; persisting `voiceEnabled` would imply a toggle that does nothing.

- **voice-stt-12 - Voice analytics events.** Doubly out of scope: depends on voice (out of scope) and on first-party telemetry/GrowthBook phone-home (out of scope). Reference: `commands/voice/voice.ts:50,124`; `voiceStreamSTT.ts:157-160`. *Local stub:* none. zcode's telemetry is local-only with no phone-home (consistent with the `/privacy-settings` stub at `cc_stub_commands.zig:31`).

### Optional hygiene (XS, take only if convenient)

These are not required for parity and add zero new capability. They only harden the honest deviation. If touched, follow conventions: pure functions in `core/`, register any new module in the `src/main.zig` comptime test block, import the runtime via `@import("zcode_runtime")`.

1. **Stub wording check.** Confirm the `/voice` stub message stays accurate (no microphone, no STT bundled). Verify no em/en dashes (current text uses a plain colon, which is fine).
2. **Test for non-collision.** The existing tests already assert `/voice` resolves to a stub and that real commands (`/model`, `/commit`) still return null. Optionally add an assertion that `/voice` is NOT in `core/removed_commands.zig` (so it keeps routing to the stub rather than being silently dropped), if such a guard does not already exist. This is defensive only.

No new files, config fields, flags, keybindings, or modules should be created in this phase.

## Verification

Because there is no functional change, verification is confined to confirming the existing stub remains correct and the build/tests are green.

1. **Build and tests:**
   - `zig build test` (custom runner at `tools/test_runner.zig`) - confirm `cc_stub_commands.zig` tests still pass, including "recognizes easter eggs and stubs" which asserts `/voice` resolves and contains "Voice".
2. **Release build + install** (per CLAUDE.md, fresh inode to preserve ad-hoc code signature):
   - `zig build -Doptimize=ReleaseFast`
   - `rm -f ~/.local/bin/zcode && cp zig-out/bin/zcode ~/.local/bin/zcode`
3. **Manual check (honest deviation is live):**
   - Start `zcode`, type `/voice`, confirm it returns the unavailable message (not "unknown command"), and that the prompt buffer is otherwise unaffected.
   - Confirm `/voice extra args` also resolves (the stub matches the leading word and is case-insensitive per `cc_stub_commands.zig:60-63`).
4. **Negative checks (nothing leaked in):**
   - `grep -ri "voiceEnabled\|VOICE_MODE\|tengu_amber_quartz\|tengu_cobalt_frost\|voice_stream\|normalizeLanguageForSTT\|getVoiceKeyterms\|pushToTalk" /Users/example/Projects/zig-code/src` returns no matches (confirms no partial scaffolding was introduced).
   - Confirm `config.preferred_language` (`core/config.zig:123`) is still documented as model-response language only and was not repurposed for STT.

**Version bump:** only if the optional hygiene items above are taken and they change a file. If nothing changes, no version bump is needed for a docs-only audit phase. If a file changes, bump the patch in `build.zig.zon` per CLAUDE.md.

**Relevant files (absolute paths):**
- `/Users/example/Projects/zig-code/src/core/cc_stub_commands.zig` - the shipped `/voice` stub (line 17) and its tests (lines 53-69).
- `/Users/example/Projects/zig-code/src/repl_commands.zig` - stub dispatch (lines 168-170).
- `/Users/example/Projects/zig-code/src/core/config.zig` - `preferred_language` (line 123), the response-language field that must NOT be confused with STT dictation language.
- `/Users/example/Projects/zig-code/src/cli/keybindings.zig` - `BindingAction` enum (no voice action; do not add one).
- Reference (read-only): `/Users/example/Downloads/claude-code-main/src/voice/voiceModeEnabled.ts`, `/Users/example/Downloads/claude-code-main/src/services/voiceStreamSTT.ts`, `/Users/example/Downloads/claude-code-main/src/services/voice.ts`, `/Users/example/Downloads/claude-code-main/src/services/voiceKeyterms.ts`, `/Users/example/Downloads/claude-code-main/src/hooks/useVoice.ts`, `/Users/example/Downloads/claude-code-main/src/commands/voice/voice.ts`, `/Users/example/Downloads/claude-code-main/src/components/LogoV2/VoiceModeNotice.tsx`, `/Users/example/Downloads/claude-code-main/src/keybindings/defaultBindings.ts`.
