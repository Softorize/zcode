#!/usr/bin/env bash
# airgap_bundle.sh - Produce a fully self-contained installation bundle
# for air-gapped environments.
#
# A bundle contains:
#   - The release binary
#   - Its cosign signature (.sig), Fulcio cert (.pem), and Sigstore bundle
#   - The CycloneDX SBOM and its signature/cert/bundle
#   - The SLSA provenance file
#   - SHA256SUMS
#   - A VERIFY.md with the exact commands to verify offline
#   - install.sh that runs the verification before copying the binary
#
# Designed for environments with no outbound network: an operator
# downloads the bundle on a connected box, transfers it over sneakernet,
# and installs with full supply-chain verification using only files in
# the tarball.
#
# Usage: airgap_bundle.sh <version> <os_arch> <source_dir> <output_dir>
#   version:    e.g. 0.10.334 (no v-prefix)
#   os_arch:    e.g. linux-x86_64, macos-aarch64
#   source_dir: directory containing signed artifacts (typically dist/)
#   output_dir: where to write the bundle tarball
set -euo pipefail

VERSION="${1:?Usage: airgap_bundle.sh <version> <os_arch> <source_dir> <output_dir>}"
OS_ARCH="${2:?Usage: airgap_bundle.sh <version> <os_arch> <source_dir> <output_dir>}"
SOURCE_DIR="${3:?Usage: airgap_bundle.sh <version> <os_arch> <source_dir> <output_dir>}"
OUTPUT_DIR="${4:?Usage: airgap_bundle.sh <version> <os_arch> <source_dir> <output_dir>}"

BINARY="zcode-${OS_ARCH}"
BUNDLE_NAME="zcode-${VERSION}-${OS_ARCH}-airgap"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ ! -d "$SOURCE_DIR" ]; then
    echo "FAIL: source directory not found: $SOURCE_DIR" >&2
    exit 1
fi
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

sha256_line() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path"
    else
        echo "FAIL: sha256sum or shasum required." >&2
        exit 1
    fi
}

mkdir -p "$STAGE/$BUNDLE_NAME"
cd "$STAGE/$BUNDLE_NAME"

# --- Required files -----------------------------------------------------
for f in "$BINARY" "$BINARY.sig" "$BINARY.pem" "$BINARY.bundle"; do
    src="$SOURCE_DIR/$f"
    if [ ! -f "$src" ]; then
        echo "FAIL: missing required artifact: $src" >&2
        exit 1
    fi
    cp "$src" "./$f"
done

# --- Required supply-chain files ---------------------------------------
for f in sbom.cdx.json sbom.cdx.json.sig sbom.cdx.json.pem sbom.cdx.json.bundle zcode.intoto.jsonl; do
    src="$SOURCE_DIR/$f"
    # Also check release/ subdir since publish-release keeps some there.
    [ -f "$src" ] || src="$SOURCE_DIR/release/$f"
    if [ -f "$src" ]; then
        cp "$src" "./$f"
    else
        echo "FAIL: missing required supply-chain artifact: $f" >&2
        exit 1
    fi
done

# --- SHA256SUMS ---------------------------------------------------------
checksum_tmp="$(mktemp)"
for f in ./*; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "SHA256SUMS" ] && continue
    sha256_line "$f"
done > "$checksum_tmp"
mv "$checksum_tmp" SHA256SUMS

# --- Install script (verifies before copying) --------------------------
cat > install.sh <<'INSTALL_EOF'
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

BINARY=$(ls zcode-*-* 2>/dev/null | grep -vE '\.(sig|pem|bundle|jsonl|md|sh)$' | head -n1)
if [ -z "$BINARY" ]; then
    echo "FAIL: no zcode binary found in bundle." >&2
    exit 1
fi

verify_sha256sums() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c SHA256SUMS
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c SHA256SUMS
    else
        echo "FAIL: sha256sum or shasum required." >&2
        exit 1
    fi
}

allow_unverified="${ZCODE_AIRGAP_ALLOW_UNVERIFIED:-0}"

echo "Step 1/4: SHA256SUMS"
verify_sha256sums

if command -v cosign >/dev/null 2>&1; then
    echo "Step 2/4: cosign verify-blob (binary)"
    COSIGN_IDENTITY_RE='^https://github.com/Softorize/zcode/\.github/workflows/release\.yml@refs/tags/v.*$'
    cosign verify-blob \
        --bundle "$BINARY.bundle" \
        --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
        --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
        "$BINARY"

    echo "Step 3/4: cosign verify-blob (SBOM)"
    cosign verify-blob \
        --bundle sbom.cdx.json.bundle \
        --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
        --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
        sbom.cdx.json
else
    if [ "$allow_unverified" = "1" ]; then
        echo "Step 2/4: cosign not on PATH, skipping cryptographic verify because ZCODE_AIRGAP_ALLOW_UNVERIFIED=1 (WARNING)."
    else
        echo "FAIL: cosign not on PATH; refusing air-gap install. Set ZCODE_AIRGAP_ALLOW_UNVERIFIED=1 only for emergency break-glass installs." >&2
        exit 1
    fi
fi

if command -v slsa-verifier >/dev/null 2>&1 && [ -f zcode.intoto.jsonl ]; then
    echo "Step 4/4: slsa-verifier"
    slsa-verifier verify-artifact \
        --provenance-path zcode.intoto.jsonl \
        --source-uri github.com/Softorize/zcode \
        "$BINARY"
else
    if [ "$allow_unverified" = "1" ]; then
        echo "Step 4/4: slsa-verifier not on PATH or provenance missing, skipping because ZCODE_AIRGAP_ALLOW_UNVERIFIED=1 (WARNING)."
    else
        echo "FAIL: slsa-verifier not on PATH or provenance missing; refusing air-gap install. Set ZCODE_AIRGAP_ALLOW_UNVERIFIED=1 only for emergency break-glass installs." >&2
        exit 1
    fi
fi

DEST="${ZCODE_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$DEST"
install -m 0755 "$BINARY" "$DEST/zcode"
echo "Installed to $DEST/zcode"
INSTALL_EOF
chmod +x install.sh

# --- Operator-facing verification walkthrough --------------------------
cat > VERIFY.md <<VERIFY_EOF
# zcode ${VERSION} air-gapped bundle

This bundle is cryptographically verifiable offline.

Contents:
$(ls -1)

## Install

\`\`\`sh
./install.sh
\`\`\`

\`install.sh\` runs SHA256SUMS, cosign bundle verification, SBOM signature
verification, and slsa-verifier before copying the binary. On failure or
missing verifier tools it refuses to install. Override the destination with
\`ZCODE_INSTALL_DIR=/opt/bin\`.

See \`docs/security/VERIFY_RELEASE.md\` in the zcode repository for the
verification theory of operation.
VERIFY_EOF

# --- Package -----------------------------------------------------------
cd "$STAGE"
tar -czf "$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz" "$BUNDLE_NAME"

echo "Air-gap bundle written to $OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
sha256_line "$OUTPUT_DIR/${BUNDLE_NAME}.tar.gz"
