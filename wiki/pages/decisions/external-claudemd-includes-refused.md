---
title: External CLAUDE.md/ZCODE.md includes refused (not prompted)
tags: [decision, gotcha]
created: 2026-05-31
updated: 2026-05-31
sources:
  - docs/parity-audit-2026-05-29/phase-24-ui-dialogs.md (Task 24.7, ui-dialogs-13)
  - src/core/instructions.zig:1179 (resolveImportPath)
  - src/core/instructions.zig:1198 (containsParentSegment)
---

# External CLAUDE.md/ZCODE.md includes refused (not prompted)

## Summary

Phase 24 Task 24.7 (ui-dialogs-13) was a CONDITIONAL build: only implement a
ClaudeMdExternalIncludesDialog IF zcode's memory loader can resolve `@include`/
`@import` directives to files OUTSIDE the workspace. Verification of
`resolveImportPath` (`src/core/instructions.zig:1179`) confirmed it cannot:
zcode refuses every external include outright, so there is nothing for the
reference's approval dialog to gate. Downgraded to a documented deviation;
no UI built. The only change shipped is a pin test.

## Key points

- The Claude Code reference shows `ClaudeMdExternalIncludesDialog` to prompt the
  user before injecting `@-includes` that resolve outside the workspace
  (`interactiveHelpers.tsx:164-170`). zcode never reaches that situation.
- `resolveImportPath` rejects, with `error.InstructionImportDenied`:
  - absolute paths (`@include /etc/passwd`),
  - any `..` segment, checked FIRST via `containsParentSegment` (so even
    `~/../etc` is rejected before the `~/` branch runs),
  - `~/` paths NOT under the explicit `.claude/` or `.zcode/` config dirs
    (`@include ~/.ssh/id_rsa`).
- The ONLY out-of-workspace includes zcode permits are `~/.claude/...` and
  `~/.zcode/...`. These are sanctioned config dirs (known config locations),
  not the workspace-relative external includes the reference dialog warns
  about, so they are correctly loaded silently.
- A failed/denied import is not fatal: the loader logs a
  `std.log.warn` and continues (`instructions.zig:671-677`).

## Details

zcode is intentionally STRICTER than the reference: it declines arbitrary
external includes rather than prompting for them. There is no class of
"arbitrary file on disk" include for a dialog to approve, so building the
overlay would add a dead code path with no consumer (violates the simplicity
rule).

The acceptance criterion for the downgraded path is a pin test, added at the
end of `src/core/instructions.zig`:
`test "resolveImportPath refuses external includes (stricter than reference)"`.
It asserts the four denial cases, that a normal relative include stays
contained under the importer's directory, and that the `~/.claude/...` form
resolves under HOME. If a future change loosens `resolveImportPath`, this test
breaks, forcing a re-evaluation of whether the external-include gate now needs
to exist.

## Related

- [[cc-parity-deep-modules]] - the parity-gap inventory over-reports; verify before building.
- [[managed-settings-dangerous-key-gate]] - the sibling Phase 24 danger gate that WAS built (names-only, interactive-only).

## Sources

- docs/parity-audit-2026-05-29/phase-24-ui-dialogs.md - Task 24.7 marks this conditional and predicts the stricter-stance outcome.
- src/core/instructions.zig:1179 - resolveImportPath containment logic (the verification evidence).
