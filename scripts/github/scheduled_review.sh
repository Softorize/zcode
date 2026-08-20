#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

BIN="${ZCODE_BIN:-./zig-out/bin/zcode}"
TARGET="${ZCODE_SCHEDULED_REVIEW_TARGET:-working}"

if [[ ! -x "${BIN}" ]]; then
  zig build -Doptimize=ReleaseSafe
fi

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

"${cmd[@]}" review "${TARGET}"
