#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <version> <target> <asset_name> <output_dir>" >&2
  exit 1
fi

version="$1"
target="$2"
asset_name="$3"
output_dir="$4"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

zig build \
  -Doptimize=ReleaseSafe \
  -Dtarget="$target" \
  -Dapp_version_override="$version"

mkdir -p "$output_dir"
binary_path="zig-out/bin/zcode"

cp "$binary_path" "$output_dir/$asset_name"
chmod +x "$output_dir/$asset_name"

echo "built $output_dir/$asset_name"
