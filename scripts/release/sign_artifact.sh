#!/usr/bin/env bash
# sign_artifact.sh - Keyless-sign any release artifact with cosign.
#
# Produces <artifact>.sig, <artifact>.pem, and <artifact>.bundle. The
# Sigstore bundle carries the signature, Fulcio certificate, and
# transparency-log proof needed for offline blob verification.
#
# Usage: sign_artifact.sh <artifact_path>
set -euo pipefail

ARTIFACT="${1:?Usage: sign_artifact.sh <artifact_path>}"

if [ ! -f "$ARTIFACT" ]; then
    echo "FAIL: artifact not found: $ARTIFACT" >&2
    exit 1
fi

if ! command -v cosign >/dev/null 2>&1; then
    echo "FAIL: cosign not on PATH." >&2
    exit 1
fi

COSIGN_YES=true cosign sign-blob \
    --yes \
    --output-signature "${ARTIFACT}.sig" \
    --output-certificate "${ARTIFACT}.pem" \
    --bundle "${ARTIFACT}.bundle" \
    "$ARTIFACT"

echo "Signed $ARTIFACT"
echo "  signature   -> ${ARTIFACT}.sig"
echo "  certificate -> ${ARTIFACT}.pem"
echo "  bundle      -> ${ARTIFACT}.bundle"
