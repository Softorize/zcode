#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <formula_path>" >&2
  exit 1
fi

: "${HOMEBREW_TAP_TOKEN:?HOMEBREW_TAP_TOKEN is required}"

formula_path="$1"
tap_repo="${HOMEBREW_TAP_REPO:-Softorize/homebrew-zcode}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

git clone "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${tap_repo}.git" "$tmpdir/tap"

mkdir -p "$tmpdir/tap/Formula"
cp "$formula_path" "$tmpdir/tap/Formula/zcode.rb"

cd "$tmpdir/tap"

if [ -z "$(git status --porcelain -- Formula/zcode.rb)" ]; then
  echo "homebrew tap already up to date"
  exit 0
fi

git config user.name "${GIT_AUTHOR_NAME:-zcode release bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git add Formula/zcode.rb
git commit -m "Update zcode formula"
git push origin HEAD

echo "published Formula/zcode.rb to ${tap_repo}"
