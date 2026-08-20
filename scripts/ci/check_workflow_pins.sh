#!/usr/bin/env bash
set -euo pipefail

root="${1:-.github/workflows}"

if [ ! -d "$root" ]; then
  echo "workflow directory not found: $root" >&2
  exit 2
fi

pattern='uses:[[:space:]]+[^#[:space:]]+@(v[0-9]+|main|master)([[:space:]#]|$)'
matches=""
if command -v rg >/dev/null 2>&1; then
  matches="$(rg -n "$pattern" "$root" || true)"
else
  matches="$(grep -RInE "$pattern" "$root" || true)"
fi

if [ -n "$matches" ]; then
  echo "FAIL: floating GitHub Actions references are not allowed. Pin actions to a commit SHA and keep the version in a comment." >&2
  echo "$matches" >&2
  exit 1
fi

echo "workflow action pins verified"
