#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Release artifact audit - validates binaries, VSIX, and release assets
# ---------------------------------------------------------------------------

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <path> [<path>...]" >&2
  exit 1
fi

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required to audit VSIX contents" >&2
  exit 1
fi

# Size thresholds (bytes)
MAX_BINARY_SIZE=$((30 * 1024 * 1024))   # 30 MB hard fail
WARN_BINARY_SIZE=$((15 * 1024 * 1024))  # 15 MB warning
MAX_VSIX_SIZE=$((5 * 1024 * 1024))      # 5 MB hard fail
WARN_VSIX_SIZE=$((1 * 1024 * 1024))     # 1 MB warning

fail=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_file_size() {
  wc -c < "$1" | tr -d ' '
}

# ---------------------------------------------------------------------------
# Size anomaly detection
# ---------------------------------------------------------------------------

check_size() {
  local path="$1"
  local max_size="$2"
  local warn_size="$3"
  local label="$4"
  local size
  size=$(get_file_size "$path")

  if [ "$size" -gt "$max_size" ]; then
    echo "FAIL: $label $(basename "$path") is ${size} bytes (max ${max_size})" >&2
    fail=1
    return 1
  fi
  if [ "$size" -gt "$warn_size" ]; then
    echo "WARN: $label $(basename "$path") is ${size} bytes (threshold ${warn_size})" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Debug symbol stripping verification
# ---------------------------------------------------------------------------

check_debug_symbols() {
  local path="$1"

  # Use strings heuristic to detect DWARF debug info regardless of binary format
  if strings "$path" 2>/dev/null | grep -qE 'DW_AT_|\.debug_info|\.debug_line|\.debug_abbrev'; then
    echo "FAIL: debug symbols detected in $(basename "$path")" >&2
    fail=1
    return 1
  fi

  # Secondary check with readelf for ELF binaries
  if command -v readelf >/dev/null 2>&1; then
    if readelf -S "$path" 2>/dev/null | grep -q '\.debug_'; then
      echo "FAIL: ELF debug sections in $(basename "$path")" >&2
      fail=1
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Binary platform/architecture validation
# ---------------------------------------------------------------------------

check_binary_platform() {
  local path="$1"
  local basename
  basename=$(basename "$path")

  if ! command -v file >/dev/null 2>&1; then
    return 0  # Skip if file command unavailable
  fi

  local file_output
  file_output=$(file "$path" 2>/dev/null) || return 0

  case "$basename" in
    *linux*x86_64*)
      if ! echo "$file_output" | grep -qiE 'ELF.*x86.64|ELF.*x86-64'; then
        echo "FAIL: expected Linux x86_64 ELF for $basename, got: $file_output" >&2
        fail=1
      fi
      ;;
    *linux*aarch64*)
      if ! echo "$file_output" | grep -qiE 'ELF.*aarch64|ELF.*ARM aarch64'; then
        echo "FAIL: expected Linux aarch64 ELF for $basename, got: $file_output" >&2
        fail=1
      fi
      ;;
    *macos*x86_64*|*darwin*x86_64*)
      if ! echo "$file_output" | grep -qiE 'Mach-O.*x86_64'; then
        echo "FAIL: expected macOS x86_64 Mach-O for $basename, got: $file_output" >&2
        fail=1
      fi
      ;;
    *macos*aarch64*|*macos*arm64*|*darwin*aarch64*)
      if ! echo "$file_output" | grep -qiE 'Mach-O.*arm64'; then
        echo "FAIL: expected macOS arm64 Mach-O for $basename, got: $file_output" >&2
        fail=1
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Secrets scanning
# ---------------------------------------------------------------------------

check_secrets() {
  local path="$1"
  local label="$2"

  local patterns=(
    'sk-ant-'          # Anthropic API keys
    'sk-[a-zA-Z0-9]{20,}'  # OpenAI-style keys
    'ghp_[a-zA-Z0-9]'  # GitHub personal tokens
    'gho_[a-zA-Z0-9]'  # GitHub OAuth tokens
    'ghs_[a-zA-Z0-9]'  # GitHub server tokens
    'AKIA[A-Z0-9]'     # AWS access keys
    'xoxb-'            # Slack bot tokens
    'xoxp-'            # Slack user tokens
    '-----BEGIN.*PRIVATE KEY-----'
  )

  for pat in "${patterns[@]}"; do
    if strings "$path" 2>/dev/null | grep -qE "$pat"; then
      echo "FAIL: potential secret pattern ($pat) found in $label $(basename "$path")" >&2
      fail=1
      return 1
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# Binary checks (composite)
# ---------------------------------------------------------------------------

check_binary() {
  local path="$1"

  check_size "$path" "$MAX_BINARY_SIZE" "$WARN_BINARY_SIZE" "binary"
  check_debug_symbols "$path"
  check_binary_platform "$path"
  check_secrets "$path" "binary"
}

# ---------------------------------------------------------------------------
# Regular file check
# ---------------------------------------------------------------------------

check_regular_file() {
  local path="$1"
  case "$path" in
    *.map)
      echo "disallowed release artifact: $path" >&2
      fail=1
      ;;
    *.sig|*.pem|*.bundle|*.intoto.jsonl)
      # Cosign signatures, Fulcio certs, bundles, and SLSA provenance ride
      # with the binaries but are short text/JSON files; skip binary checks.
      ;;
    *zcode*)
      # Known binary asset - run full binary checks
      check_binary "$path"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# VSIX checks
# ---------------------------------------------------------------------------

check_vsix() {
  local path="$1"
  local entry=""

  # ZIP integrity test
  if ! unzip -t "$path" >/dev/null 2>&1; then
    echo "FAIL: VSIX ZIP integrity check failed for $(basename "$path")" >&2
    fail=1
    return
  fi

  # Size check
  check_size "$path" "$MAX_VSIX_SIZE" "$WARN_VSIX_SIZE" "VSIX"

  # Required entries
  local listing
  listing=$(unzip -Z1 "$path" 2>/dev/null)

  if ! echo "$listing" | grep -q '\[Content_Types\].xml'; then
    echo "FAIL: VSIX missing [Content_Types].xml in $(basename "$path")" >&2
    fail=1
  fi

  # Check for disallowed entries
  while IFS= read -r entry; do
    case "$entry" in
      *.map|*.ts|*.tsx|*/src/*|*/tsconfig.json|*/package-lock.json)
        echo "disallowed VSIX entry in $(basename "$path"): $entry" >&2
        fail=1
        ;;
    esac
  done <<< "$listing"

  # JS output validation - check for sourceMapping URLs
  local js_content
  js_content=$(unzip -p "$path" "extension/out/extension.js" 2>/dev/null) || true
  if [ -n "$js_content" ]; then
    if echo "$js_content" | grep -q 'sourceMappingURL'; then
      echo "FAIL: sourceMappingURL found in compiled JS in $(basename "$path")" >&2
      fail=1
    fi
  fi

  # Secrets scan on extracted JS
  local tmpjs
  tmpjs=$(mktemp)
  unzip -p "$path" "extension/out/extension.js" > "$tmpjs" 2>/dev/null || true
  if [ -s "$tmpjs" ]; then
    check_secrets "$tmpjs" "VSIX JS"
  fi
  rm -f "$tmpjs"
}

# ---------------------------------------------------------------------------
# Complete release-set validation
# ---------------------------------------------------------------------------

require_release_file() {
  local path="$1"
  local label="$2"
  if [ ! -f "$path" ]; then
    echo "FAIL: missing required release artifact ($label): $path" >&2
    fail=1
  fi
}

require_checksum_entry() {
  local checksum_file="$1"
  local name="$2"
  if ! awk -v n="$name" '$2 == n { found=1 } END { exit found ? 0 : 1 }' "$checksum_file"; then
    echo "FAIL: SHA256SUMS missing entry for $name" >&2
    fail=1
  fi
}

check_release_set() {
  local root="$1"
  local checksum_file="$root/release/SHA256SUMS"
  local has_primary=0
  local asset=""

  for asset in zcode-linux-x86_64 zcode-linux-aarch64 zcode-macos-x86_64 zcode-macos-aarch64; do
    if [ -f "$root/$asset" ]; then
      has_primary=1
    fi
  done

  # Only enforce the complete release graph for release dist directories.
  # Single-file audits, such as VSIX-only CI checks, should stay lightweight.
  if [ "$has_primary" -eq 0 ]; then
    return
  fi

  for asset in zcode-linux-x86_64 zcode-linux-aarch64 zcode-macos-x86_64 zcode-macos-aarch64; do
    require_release_file "$root/$asset" "$asset binary"
    require_release_file "$root/$asset.sig" "$asset cosign signature"
    require_release_file "$root/$asset.pem" "$asset Fulcio certificate"
    require_release_file "$root/$asset.bundle" "$asset Sigstore bundle"
  done

  if ! compgen -G "$root/zcode-vscode-*.vsix" >/dev/null; then
    echo "FAIL: missing required release artifact: zcode-vscode-*.vsix" >&2
    fail=1
  fi

  require_release_file "$root/zcode.intoto.jsonl" "SLSA provenance"
  require_release_file "$root/release/update.json" "update manifest"
  require_release_file "$root/release/zcode.rb" "Homebrew formula"
  require_release_file "$checksum_file" "SHA256SUMS"
  require_release_file "$root/release/sbom.cdx.json" "CycloneDX SBOM"
  require_release_file "$root/release/sbom.cdx.json.sig" "SBOM cosign signature"
  require_release_file "$root/release/sbom.cdx.json.pem" "SBOM Fulcio certificate"
  require_release_file "$root/release/sbom.cdx.json.bundle" "SBOM Sigstore bundle"

  if [ -f "$checksum_file" ]; then
    for asset in zcode-linux-x86_64 zcode-linux-aarch64 zcode-macos-x86_64 zcode-macos-aarch64; do
      require_checksum_entry "$checksum_file" "$asset"
      require_checksum_entry "$checksum_file" "$asset.sig"
      require_checksum_entry "$checksum_file" "$asset.pem"
      require_checksum_entry "$checksum_file" "$asset.bundle"
    done
    require_checksum_entry "$checksum_file" "zcode.intoto.jsonl"
    require_checksum_entry "$checksum_file" "sbom.cdx.json"
    require_checksum_entry "$checksum_file" "sbom.cdx.json.sig"
    require_checksum_entry "$checksum_file" "sbom.cdx.json.pem"
    require_checksum_entry "$checksum_file" "sbom.cdx.json.bundle"
  fi
}

# ---------------------------------------------------------------------------
# Walk targets
# ---------------------------------------------------------------------------

walk_target() {
  local target="$1"
  local file=""

  if [ -d "$target" ]; then
    while IFS= read -r file; do
      case "$file" in
        *.vsix) check_vsix "$file" ;;
        *) check_regular_file "$file" ;;
      esac
    done < <(find "$target" -type f | sort)
    check_release_set "$target"
    return
  fi

  if [ ! -e "$target" ]; then
    echo "missing audit target: $target" >&2
    fail=1
    return
  fi

  case "$target" in
    *.vsix) check_vsix "$target" ;;
    *) check_regular_file "$target" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

for target in "$@"; do
  walk_target "$target"
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "release artifact audit passed"
