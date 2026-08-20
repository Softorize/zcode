## Summary

- what changed
- why it changed
- any compatibility or migration impact

## Validation

- [ ] `zig fmt --check src/`
- [ ] `zig build -Doptimize=ReleaseSafe`
- [ ] `zig build test`
- [ ] `npm run compile` in `extensions/vscode`
- [ ] docs/help text updated where needed

## Notes

- security-sensitive changes called out
- release or workflow changes validated with `bash -n` where relevant
