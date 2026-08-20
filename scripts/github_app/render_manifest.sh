#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <web_base_url> [github_repo_url]" >&2
  exit 1
fi

base_url="${1%/}"
repo_url="${2:-https://github.com/Softorize/zcode}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_path="${script_dir}/../../.github/github-app-manifest.json"

python3 - "$template_path" "$base_url" "$repo_url" <<'PY'
import json
import pathlib
import sys

template_path = pathlib.Path(sys.argv[1])
base_url = sys.argv[2].rstrip("/")
repo_url = sys.argv[3].rstrip("/")

data = json.loads(template_path.read_text())

def replace(value):
    if isinstance(value, str):
        return (
            value.replace("__ZCODE_WEB_BASE_URL__", base_url)
            .replace("__ZCODE_GITHUB_REPO_URL__", repo_url)
        )
    if isinstance(value, list):
        return [replace(item) for item in value]
    if isinstance(value, dict):
        return {key: replace(item) for key, item in value.items()}
    return value

print(json.dumps(replace(data), indent=2))
PY
