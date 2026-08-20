---
title: Plugin user-vs-workspace scope collision when HOME == cwd in tests
tags: [gotcha, testing]
created: 2026-05-30
updated: 2026-05-30
sources:
  - src/core/plugins.zig:117 (list walks both user and workspace roots)
  - src/core/paths.zig:30 (resolve keys zcode_home off HOME)
  - src/core/plugin_settings.zig (Task 17.1 tests)
---

# Plugin user-vs-workspace scope collision when HOME == cwd in tests

## Summary
`plugins.list` discovers plugins from two roots: the user root
`<zcode_home>/plugins` (where `zcode_home = <HOME>/.zcode`) and the workspace
root `<cwd>/.zcode/plugins`. In a test that both pins `HOME` to the tmp dir
(needed so user-scope settings resolve hermetically) AND passes that same tmp
dir as `cwd`, the two roots become the SAME directory, so every installed plugin
is found twice -- once tagged `.user`, once `.workspace`. `list().len` is double
what you expect and `disableAll` flips each plugin twice.

## Key points
- Fix: keep `HOME` and `cwd` distinct. Pin `HOME` to the tmp root (plugin
  manifests under `<root>/.zcode/plugins/...`) and use a separate subdir
  (`<root>/proj`) as `cwd` so the workspace root has no plugins.
- This is the same hermetic-HOME technique as
  [[hermetic-home-for-settings-sources]] but with an extra constraint: the
  settings-sources tests don't double-count, plugins do, because
  `plugins.list` walks BOTH roots unconditionally.
- The per-scope `plugin_settings.json` files also collide when `HOME == cwd`
  (user file `<HOME>/.zcode/plugin_settings.json` vs workspace file
  `<cwd>/.zcode/plugin_settings.json`). Any test asserting that "workspace
  overrides user" MUST separate the two dirs or both writes hit one file.

## Details
`paths.resolve` (src/core/paths.zig:30) prefers an existing `<HOME>/.zcode` for
`zcode_home`. `paths.workspacePathAlloc(cwd, ...)` joins `<cwd>/.zcode/...`. When
the two base dirs are equal, user and workspace scope are indistinguishable on
disk. Production never hits this (HOME is the operator home, cwd is a project),
but tmp-dir tests trivially do unless you separate them.

## Related
- [[hermetic-home-for-settings-sources]] - the HOME-pinning technique; this page
  adds the "also separate cwd for plugins" constraint.
