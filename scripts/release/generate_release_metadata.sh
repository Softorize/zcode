#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <version> <repo> <dist_dir> <output_dir>" >&2
  exit 1
fi

version="$1"
repo="$2"
dist_dir="$3"
output_dir="$4"

release_tag="v$version"
release_url="https://github.com/$repo/releases/tag/$release_tag"
download_base_url="https://github.com/$repo/releases/download/$release_tag"

mkdir -p "$output_dir"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

sha_macos_aarch64=""
sha_macos_x86_64=""
sha_linux_aarch64=""
sha_linux_x86_64=""
url_macos_aarch64=""
url_macos_x86_64=""
url_linux_aarch64=""
url_linux_x86_64=""

checksum_file="$output_dir/SHA256SUMS"
: > "$checksum_file"

assets_json=""
sep=""

shopt -s nullglob
assets=( "$dist_dir"/zcode-* )
if [ -f "$dist_dir/zcode.intoto.jsonl" ]; then
  assets+=( "$dist_dir/zcode.intoto.jsonl" )
fi
for release_artifact in \
  "$output_dir/sbom.cdx.json" \
  "$output_dir/sbom.cdx.json.sig" \
  "$output_dir/sbom.cdx.json.pem" \
  "$output_dir/sbom.cdx.json.bundle"
do
  if [ -f "$release_artifact" ]; then
    assets+=( "$release_artifact" )
  fi
done
shopt -u nullglob

if [ "${#assets[@]}" -eq 0 ]; then
  echo "no release assets found under $dist_dir" >&2
  exit 1
fi

for path in "${assets[@]}"; do
  name="$(basename "$path")"
  sha="$(sha256_file "$path")"
  url="$download_base_url/$name"
  kind="binary"
  os="any"
  arch="any"
  include_in_update_json=0

  case "$name" in
    zcode-vscode-*.vsix)
      kind="editor-vscode"
      include_in_update_json=1
      ;;
    zcode-macos-aarch64|zcode-macos-x86_64|zcode-linux-aarch64|zcode-linux-x86_64)
      asset_tail="${name#zcode-}"
      os="${asset_tail%%-*}"
      arch="${asset_tail#*-}"
      arch="${arch%.exe}"
      include_in_update_json=1
      ;;
    *.sig|*.pem|*.bundle|*.intoto.jsonl|sbom.cdx.json)
      ;;
    *)
      echo "skipping non-installable zcode-prefixed artifact in update.json: $name" >&2
      ;;
  esac

  case "$name" in
    zcode-macos-aarch64)
      sha_macos_aarch64="$sha"
      url_macos_aarch64="$url"
      ;;
    zcode-macos-x86_64)
      sha_macos_x86_64="$sha"
      url_macos_x86_64="$url"
      ;;
    zcode-linux-aarch64)
      sha_linux_aarch64="$sha"
      url_linux_aarch64="$url"
      ;;
    zcode-linux-x86_64)
      sha_linux_x86_64="$sha"
      url_linux_x86_64="$url"
      ;;
  esac

  printf '%s  %s\n' "$sha" "$name" >> "$checksum_file"

  if [ "$include_in_update_json" -eq 1 ]; then
    assets_json+="${sep}    {
      \"name\": \"$name\",
      \"kind\": \"$kind\",
      \"os\": \"$os\",
      \"arch\": \"$arch\",
      \"url\": \"$url\",
      \"sha256\": \"$sha\"
    }"
    sep=$',\n'
  fi
done

cat > "$output_dir/update.json" <<EOF
{
  "version": "$version",
  "release_url": "$release_url",
  "checksums_url": "$download_base_url/SHA256SUMS",
  "assets": [
$assets_json
  ]
}
EOF

require_asset() {
  local sha_value="$1"
  local url_value="$2"
  local label="$3"
  if [ -z "$sha_value" ] || [ -z "$url_value" ]; then
    echo "missing asset metadata for $label" >&2
    exit 1
  fi
}

require_asset "$sha_macos_aarch64" "$url_macos_aarch64" "zcode-macos-aarch64"
require_asset "$sha_macos_x86_64" "$url_macos_x86_64" "zcode-macos-x86_64"
require_asset "$sha_linux_aarch64" "$url_linux_aarch64" "zcode-linux-aarch64"
require_asset "$sha_linux_x86_64" "$url_linux_x86_64" "zcode-linux-x86_64"

cat > "$output_dir/zcode.rb" <<EOF
class Zcode < Formula
  desc "Enterprise-first coding agent CLI written in Zig"
  homepage "https://github.com/$repo"
  version "$version"

  on_macos do
    if Hardware::CPU.arm?
      url "$url_macos_aarch64"
      sha256 "$sha_macos_aarch64"
    else
      url "$url_macos_x86_64"
      sha256 "$sha_macos_x86_64"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "$url_linux_aarch64"
      sha256 "$sha_linux_aarch64"
    else
      url "$url_linux_x86_64"
      sha256 "$sha_linux_x86_64"
    end
  end

  def install
    if OS.mac? && Hardware::CPU.arm?
      bin.install "zcode-macos-aarch64" => "zcode"
    elsif OS.mac? && Hardware::CPU.intel?
      bin.install "zcode-macos-x86_64" => "zcode"
    elsif OS.linux? && Hardware::CPU.arm?
      bin.install "zcode-linux-aarch64" => "zcode"
    elsif OS.linux? && Hardware::CPU.intel?
      bin.install "zcode-linux-x86_64" => "zcode"
    else
      odie "unsupported platform"
    end
  end

  test do
    assert_match "zcode", shell_output("#{bin}/zcode version")
  end
end
EOF

echo "wrote $checksum_file"
echo "wrote $output_dir/update.json"
echo "wrote $output_dir/zcode.rb"
