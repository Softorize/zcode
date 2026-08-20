#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <asset_path>" >&2
  exit 1
fi

asset_path="$1"

if [ ! -f "$asset_path" ]; then
  echo "asset not found: $asset_path" >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "macos signing only runs on Darwin" >&2
  exit 1
fi

if [ -z "${APPLE_SIGNING_CERT_B64:-}" ] || [ -z "${APPLE_SIGNING_CERT_PASSWORD:-}" ] || [ -z "${APPLE_DEVELOPER_ID_APPLICATION:-}" ]; then
  echo "macos signing secrets not configured; leaving $asset_path unsigned"
  exit 0
fi

tmpdir="$(mktemp -d)"
cleanup() {
  if [ -n "${keychain_name:-}" ]; then
    security delete-keychain "$keychain_name" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

cert_path="$tmpdir/signing-cert.p12"
printf '%s' "$APPLE_SIGNING_CERT_B64" | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))' > "$cert_path"

keychain_name="zcode-release-$(uuidgen).keychain-db"
keychain_password="$(uuidgen)"

security create-keychain -p "$keychain_password" "$keychain_name"
security set-keychain-settings -lut 21600 "$keychain_name"
security unlock-keychain -p "$keychain_password" "$keychain_name"
security import "$cert_path" \
  -k "$keychain_name" \
  -P "$APPLE_SIGNING_CERT_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$keychain_password" \
  "$keychain_name"
security list-keychains -d user -s "$keychain_name" login.keychain-db

codesign --force --options runtime --timestamp --sign "$APPLE_DEVELOPER_ID_APPLICATION" "$asset_path"
codesign --verify --verbose=2 "$asset_path"

if [ -n "${APPLE_NOTARY_APPLE_ID:-}" ] && [ -n "${APPLE_NOTARY_TEAM_ID:-}" ] && [ -n "${APPLE_NOTARY_PASSWORD:-}" ]; then
  zip_path="$tmpdir/$(basename "$asset_path").zip"
  ditto -c -k --keepParent "$asset_path" "$zip_path"
  xcrun notarytool submit "$zip_path" \
    --apple-id "$APPLE_NOTARY_APPLE_ID" \
    --team-id "$APPLE_NOTARY_TEAM_ID" \
    --password "$APPLE_NOTARY_PASSWORD" \
    --wait
fi

echo "signed $asset_path"
