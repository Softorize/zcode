# zcode VS Code Extension

This extension is the first-party VS Code surface for `zcode`.

Current commands:

- `zcode: Status`
- `zcode: Run Prompt`
- `zcode: Review Working Tree`
- `zcode: Apply Selected Patch`
- `zcode: Share Session`
- `zcode: Web Handoff Session`
- `zcode: Import Shared Session`

The extension talks to `zcode` through `zcode api serve`, so the CLI remains the source of truth for execution, review, patch application, and session handoff/import.

Notable behaviors:

- uses the structured `session.list` API to offer a session picker for share and web handoff
- applies selected unified diffs through `diff.apply`
- supports a configurable `zcode.binaryPath` setting when the CLI is not on the default `PATH`

## Local development

```bash
cd extensions/vscode
npm install
npm run compile
npm run package
```

Open the repo in VS Code, then launch the extension host from the debugger.
