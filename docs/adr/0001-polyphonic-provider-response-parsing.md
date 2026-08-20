# Provider response parsing stays polyphonic, not per-adapter

**Status:** accepted

Provider response parsing (`src/providers/extractors.zig`: `extractFirstText`,
`extractNativeToolCalls`, `parseSseText`) is a polyphonic dispatcher that tries
each known response shape in turn (`extractOpenAI` → `extractAnthropic` →
`extractGemini` → `extractOllama`). An architecture review suggested moving each
provider's parsing into its own adapter behind the `ProviderAdapter` VTable and
dropping the shared dispatcher, to remove the "sideways leak" of provider
knowledge into a shared module.

We deliberately keep the polyphonic design.

## Why

1. **The per-provider parsers are already separated.** `extractOpenAI`,
   `extractAnthropic`, etc. are distinct functions; the only shared thing is the
   small "try each" dispatcher. The locality the review wanted mostly exists.
2. **The dispatcher is load-bearing robustness, not an accident.** Several
   providers do not return their "own" canonical shape: `openai-compatible`,
   `groq`, `deepseek`, `azure`, and `local`/`ollama` all emit OpenAI-shaped
   responses, and proxies like `openrouter` can return varying shapes depending
   on the backing model. Trying each shape tolerates that variance; binding each
   adapter to exactly one parser would regress it.
3. **It sits on the critical LLM-response path.** The risk of a subtle parsing
   regression outweighs the marginal gain of a slightly cleaner seam.

## Consequence

Future architecture reviews should not re-suggest splitting provider parsing
into per-adapter parsers. If a specific provider ever needs bespoke parsing that
the dispatcher cannot express, add a provider-specific branch to the dispatcher
(or a primary-parser hint on the VTable with the polyphonic path kept as
fallback) rather than removing the shared dispatcher.
