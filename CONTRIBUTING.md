# Contributing to zcode

Thanks for contributing.

## Getting started

Prerequisites:

- Zig `0.16.0`
- Node.js `22` for the VS Code extension
- Git

Bootstrap and verify the repo:

```bash
zig build
zig build test

cd extensions/vscode
npm ci
npm run compile
```

Recommended pre-push checks from the repo root:

```bash
zig fmt --check src/
zig build -Doptimize=ReleaseSafe
zig build test

cd extensions/vscode
npm ci
npm run compile
npm run package
```

## Change scope

- Keep pull requests narrowly scoped.
- Do not mix refactors with behavior changes unless they are directly coupled.
- Update docs and help text when CLI flags, commands, config fields, or workflows change.
- Add or update tests for parser changes, protocol changes, and user-facing command flows.

## Project-specific notes

- Use the `mock` provider for deterministic CLI and REPL verification where possible.
- If you change release or GitHub automation scripts, validate them with `bash -n`.
- If you change MCP, session, or updater behavior, include a smoke test path in the PR description.
- Security-sensitive changes should document file-permission, auth, and failure-mode impacts.

## Pull requests

Before opening a PR, make sure:

- the branch builds cleanly
- tests pass locally
- new commands appear in `README.md` and REPL help where relevant
- migrations or compatibility behavior are called out explicitly

## Security issues

Do not open public issues for suspected vulnerabilities. Follow [SECURITY.md](SECURITY.md) instead.
