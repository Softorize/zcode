# Permission rule precedence: decide() vs match(), and the args-glob colon trap

## Two evaluation paths in core/permission_rules.zig

There are now TWO ways to evaluate the rule store, and they intentionally
disagree:

- `Store.match(cwd, tool, args)` reverse-iterates and returns the LAST-defined
  rule of ANY action that matches. This is "latest-matching-rule-wins". It is
  kept ONLY for the debug surface (`/permissions explain`) and existing
  round-trip tests. Do NOT use it on the enforcement hot path.
- `Store.decide(cwd, tool, args)` applies behavior-class precedence: scan ALL
  deny rules first (regardless of list position), then ALL ask rules, then ALL
  allow rules; first match within the winning class wins. A deny rule anywhere
  beats an allow rule anywhere. This mirrors the reference
  `hasPermissionsToUseToolInner` (permissions.ts:1169-1297, steps 1a/1b/2b).

The tool gate in `agent_tools.zig` `executeToolCall` drives its switch off
`decide()`. The load-bearing regression that `decide()` fixes:
`deny Bash(curl*)` defined BEFORE `allow Bash(*)` must DENY. Under the old
`match()` it returned ALLOW (the allow was the last-defined matching rule).

Both `match` and `decide` share one predicate, `ruleMatches`, so scope/tool/args
matching cannot drift between them. `args_contains.len == 0` is the tool-wide
form (matches any args), mapping to the reference's `ruleContent === undefined`.

## The args-glob colon trap (cost me 3 failing tests)

zcode's `argsMatch` does NOT understand the reference's `tool:subcommand`
colon convention. The reference writes `Bash(curl:*)` to mean "any curl
command". In zcode, the args pattern is matched against the SERIALIZED JSON tool
args (e.g. `{"command":"curl evil.com"}`) via `globContains` (unanchored glob).
A pattern containing `*` is treated as a glob; a plain pattern is a substring
check.

So `curl:*` looks for the literal substring `curl:` in the JSON, which NEVER
appears (the JSON has `curl ` with a space, not `curl:`). The pattern that
actually matches is `curl*` (no colon). When porting reference rule strings into
zcode tests or rules, drop the `:` subcommand separator and use a plain glob
against the JSON args, or write `*` for tool-wide.

See `core/permission_rules.zig` test "args pattern with star uses glob" for the
canonical example (`git commit*`, not `git commit:*`).
