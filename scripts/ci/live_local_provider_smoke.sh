#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${ZCODE_LIVE_LOCAL_BASE_URL:-${OLLAMA_BASE_URL:-}}"
MODEL="${ZCODE_LIVE_LOCAL_MODEL:-}"
PROMPT="${ZCODE_LIVE_LOCAL_PROMPT:-configure my local 32 billion parameter with ollama on my spark server}"
REQUIRED="${ZCODE_LIVE_LOCAL_REQUIRED:-0}"
BIN="${ZCODE_LIVE_LOCAL_BIN:-zig-out/bin/zcode}"

if [ -z "$BASE_URL" ] || [ -z "$MODEL" ]; then
  if [ "$REQUIRED" = "1" ]; then
    echo "live local provider smoke requires ZCODE_LIVE_LOCAL_BASE_URL/OLLAMA_BASE_URL and ZCODE_LIVE_LOCAL_MODEL" >&2
    exit 1
  fi
  echo "skipping live local provider smoke; base URL or model not configured"
  exit 0
fi

if [ ! -x "$BIN" ]; then
  echo "zcode binary not found or not executable: $BIN" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

json_output="$(
  HOME="$tmpdir" \
  OLLAMA_BASE_URL="$BASE_URL" \
  "$BIN" --provider local --model "$MODEL" --sandbox read-only exec --json "$PROMPT"
)"

printf '%s\n' "$json_output"

python3 - <<'PY' "$json_output"
import json
import sys

payload = json.loads(sys.argv[1])
response = payload.get("response", "")
tool_calls = payload.get("tool_calls", [])

lower = response.lower()
for needle in ("would you like", "shall i proceed", "should i proceed"):
    if needle in lower:
        raise SystemExit(f"live local smoke failed: confirmation-seeking response detected: {needle}")

if not tool_calls and "final_no_action" not in lower and "execution blocked by the current sandbox" not in lower:
    raise SystemExit("live local smoke failed: expected tool activity or a concrete sandbox blocker")

print("live local smoke passed")
PY
