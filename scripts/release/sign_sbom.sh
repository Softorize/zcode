#!/usr/bin/env bash
# sign_sbom.sh - Keyless-sign the CycloneDX SBOM with cosign + Sigstore.
# Thin wrapper over sign_artifact.sh so SBOM and binary signing share
# one code path and one audit trail.
#
# Usage: sign_sbom.sh <sbom_path>
set -euo pipefail

SBOM="${1:?Usage: sign_sbom.sh <sbom_path>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/sign_artifact.sh" "$SBOM"
