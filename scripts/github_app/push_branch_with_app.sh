#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <owner/repo> <branch> [local_ref]" >&2
  exit 1
fi

repo="$1"
branch="$2"
local_ref="${3:-HEAD}"
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

if [[ -z "$token" ]]; then
  echo "GITHUB_TOKEN or GH_TOKEN is required" >&2
  exit 1
fi

remote_url="https://x-access-token:${token}@github.com/${repo}.git"
git push "$remote_url" "${local_ref}:${branch}"
