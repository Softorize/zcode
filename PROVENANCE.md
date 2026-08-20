# Source provenance

`zcode` is intended for release under Apache-2.0. Before the repository is made
public, maintainers must be able to establish that every distributed source and
documentation file is either original work, used under a compatible license, or
reimplemented solely from permitted public behavior and documentation.

## Current review status

Publication is blocked pending review. The tree contains many comments and
internal audit records describing code, prompts, word lists, schemas, and
behavior as "ported" or "verbatim" from Claude Code. Historical planning
material also records use of a leaked source-map artifact. Those statements are
provenance evidence; removing the wording does not establish independent
authorship.

## Required clearance process

For each flagged implementation:

1. Identify the author and the material consulted.
2. Classify the source as public documentation, black-box observation,
   compatible open-source code, or non-public/reference source.
3. Record any applicable license and attribution requirement.
4. Replace code derived from non-public or incompatible material through an
   independently specified and implemented clean-room process.
5. Have a maintainer and qualified legal reviewer sign off on the resulting
   inventory.
6. Only then rewrite Git history if it contains material that cannot be
   distributed. Rotate any exposed credentials before the rewrite.

Because GitHub publishes reachable history, deleting or sanitizing a file in
the current tree is not sufficient. After clearance, either publish a new
squashed repository from the cleared tree or perform an explicitly approved
history rewrite and force-push. Do not reuse the current history by default.

## Known review clusters

- Model-facing prompts, tool descriptions, and schemas.
- Security and permission constants and allowlists.
- Spinner, completion, slug, and example-command word lists.
- Claude Code compatibility commands and configuration behavior.
- The `docs/parity-audit-2026-05-29/` corpus and related gap matrices.
- Captured reference fixtures under `scenarios/` and capture tooling.

This file is a release gate, not a claim that the current tree has been cleared.
