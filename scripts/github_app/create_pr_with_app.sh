#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "usage: $0 <owner/repo> <head_branch> <base_branch> <title> <body>" >&2
  exit 1
fi

repo="$1"
head="$2"
base="$3"
title="$4"
body="$5"

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$token" ]]; then
  echo "GITHUB_TOKEN or GH_TOKEN is required" >&2
  exit 1
fi

gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  "/repos/${repo}/pulls" \
  -f head="$head" \
  -f base="$base" \
  -f title="$title" \
  -f body="$body"
