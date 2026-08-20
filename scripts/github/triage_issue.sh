#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

BIN="${ZCODE_BIN:-./zig-out/bin/zcode}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"

if [[ ! -x "${BIN}" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

if [[ -z "${EVENT_PATH}" || ! -f "${EVENT_PATH}" ]]; then
  echo "GITHUB_EVENT_PATH is required" >&2
  exit 1
fi

TITLE="$(python3 - "${EVENT_PATH}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
issue = data.get("issue", {})
print(issue.get("title", ""), end="")
PY
)"

BODY="$(python3 - "${EVENT_PATH}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
issue = data.get("issue", {})
print(issue.get("body", ""), end="")
PY
)"

PROMPT=$(cat <<EOF
Triage this GitHub issue for the repository.

Return:
1. A short summary.
2. Suspected area or owner.
3. Missing information.
4. Recommended next action.

Issue title:
${TITLE}

Issue body:
${BODY}
EOF
)

cmd=("${BIN}")
if [[ -n "${ZCODE_PROVIDER:-}" ]]; then
  cmd+=(--provider "${ZCODE_PROVIDER}")
fi
if [[ -n "${ZCODE_MODEL:-}" ]]; then
  cmd+=(--model "${ZCODE_MODEL}")
fi
if [[ -n "${ZCODE_AGENT:-}" ]]; then
  cmd+=(--agent "${ZCODE_AGENT}")
fi

"${cmd[@]}" run "${PROMPT}"
