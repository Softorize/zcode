#!/usr/bin/env bash
# generate_sbom.sh - Generate a CycloneDX SBOM for zcode.
# Usage: generate_sbom.sh <version> <output_dir>
set -euo pipefail

VERSION="${1:?Usage: generate_sbom.sh <version> <output_dir>}"
OUTPUT_DIR="${2:?Usage: generate_sbom.sh <version> <output_dir>}"

mkdir -p "$OUTPUT_DIR"

ZIG_VERSION=$(zig version 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SERIAL="urn:uuid:$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")"

cat > "$OUTPUT_DIR/sbom.cdx.json" <<SBOM_EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "serialNumber": "$SERIAL",
  "version": 1,
  "metadata": {
    "timestamp": "$TIMESTAMP",
    "tools": [
      {
        "vendor": "Softorize",
        "name": "zcode-sbom-generator",
        "version": "$VERSION"
      }
    ],
    "component": {
      "type": "application",
      "name": "zcode",
      "version": "$VERSION",
      "description": "Enterprise-first coding agent CLI",
      "licenses": [
        {
          "license": {
            "id": "Apache-2.0"
          }
        }
      ],
      "purl": "pkg:generic/zcode@$VERSION"
    }
  },
  "components": [
    {
      "type": "library",
      "name": "zig-stdlib",
      "version": "$ZIG_VERSION",
      "description": "Zig standard library (only dependency - no external packages)",
      "purl": "pkg:generic/zig@$ZIG_VERSION",
      "scope": "required"
    }
  ],
  "dependencies": [
    {
      "ref": "pkg:generic/zcode@$VERSION",
      "dependsOn": [
        "pkg:generic/zig@$ZIG_VERSION"
      ]
    }
  ]
}
SBOM_EOF

echo "SBOM written to $OUTPUT_DIR/sbom.cdx.json"
