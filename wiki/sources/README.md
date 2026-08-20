# sources/

Raw, **immutable** inputs for this project's wiki. Drop files here, then ask Claude to `ingest sources/filename`.

Good candidates:
- Architecture diagrams and design docs
- Post-mortems and incident reports
- Meeting notes where a decision was made
- Debugging session transcripts
- Customer/stakeholder requirements docs
- Third-party API docs (or excerpts) specific to how this project uses them

Rules:
- Never edit a file once it is added. If the source changes, save as a new file with a suffix (e.g. `-v2`).
- Use descriptive filenames: `post-mortem-2026-03-redis-outage.md` beats `notes.md`.
- No spaces. Use `kebab-case`.
