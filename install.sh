#!/usr/bin/env bash
set -euo pipefail

repo="${ZCODE_REPO:-Softorize/zcode}"
version="${ZCODE_VERSION:-}"
install_dir="${ZCODE_INSTALL_DIR:-$HOME/.local/bin}"
require_signature="${ZCODE_INSTALL_REQUIRE_SIGNATURE:-0}"
cosign_identity_re="${ZCODE_INSTALL_COSIGN_IDENTITY_RE:-^https://github.com/Softorize/zcode/\\.github/workflows/release\\.yml@refs/tags/v.*$}"
cosign_oidc_issuer="${ZCODE_INSTALL_COSIGN_OIDC_ISSUER:-https://token.actions.githubusercontent.com}"

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *)
      echo "unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "aarch64" ;;
    x86_64|amd64) echo "x86_64" ;;
    *)
      echo "unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    echo "sha256sum or shasum is required" >&2
    exit 1
  fi
}

verify_signature_if_available() {
  local asset_path="$1"
  local bundle_path="$2"

  if [ ! -s "$bundle_path" ]; then
    if [ "$require_signature" = "1" ]; then
      echo "signature bundle for $asset not found; refusing install because ZCODE_INSTALL_REQUIRE_SIGNATURE=1" >&2
      exit 1
    fi
    echo "Warning: signature bundle for $asset not found; checksum-only install." >&2
    return 0
  fi

  if ! command -v cosign >/dev/null 2>&1; then
    if [ "$require_signature" = "1" ]; then
      echo "cosign is required because ZCODE_INSTALL_REQUIRE_SIGNATURE=1" >&2
      exit 1
    fi
    echo "Warning: cosign not found; checksum-only install. Set ZCODE_INSTALL_REQUIRE_SIGNATURE=1 to enforce signatures." >&2
    return 0
  fi

  echo "Verifying Sigstore bundle..."
  cosign verify-blob \
    --bundle "$bundle_path" \
    --certificate-identity-regexp "$cosign_identity_re" \
    --certificate-oidc-issuer "$cosign_oidc_issuer" \
    "$asset_path"
}

os="$(detect_os)"
arch="$(detect_arch)"
asset="zcode-${os}-${arch}"

if [ -n "$version" ]; then
  base_url="https://github.com/${repo}/releases/download/v${version}"
else
  base_url="https://github.com/${repo}/releases/latest/download"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

asset_path="$tmpdir/$asset"
bundle_path="$tmpdir/$asset.bundle"
checksums_path="$tmpdir/SHA256SUMS"

echo "Downloading $asset..."
curl -fsSL -o "$asset_path" "$base_url/$asset"
curl -fsSL -o "$checksums_path" "$base_url/SHA256SUMS"
if [ "$require_signature" = "1" ]; then
  curl -fsSL -o "$bundle_path" "$base_url/$asset.bundle"
else
  if ! curl -fsSL -o "$bundle_path" "$base_url/$asset.bundle" 2>/dev/null; then
    rm -f "$bundle_path"
  fi
fi

expected_sha="$(awk -v asset="$asset" '
  $2 == asset { print $1; exit }
  $2 == "*" asset { print $1; exit }
' "$checksums_path")"

if [ -z "$expected_sha" ]; then
  echo "checksum entry for $asset not found in SHA256SUMS" >&2
  exit 1
fi

actual_sha="$(sha256_file "$asset_path")"
if [ "$actual_sha" != "$expected_sha" ]; then
  echo "checksum mismatch for $asset" >&2
  echo "expected: $expected_sha" >&2
  echo "actual:   $actual_sha" >&2
  exit 1
fi

verify_signature_if_available "$asset_path" "$bundle_path"

mkdir -p "$install_dir"
install -m 0755 "$asset_path" "$install_dir/zcode"

echo "Installed zcode to $install_dir/zcode"
"$install_dir/zcode" version || true
